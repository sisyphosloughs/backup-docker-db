# shellcheck shell=bash
#
# db-dump-lib.sh — shared helpers for the per-stack db-dump.sh scripts.
#
# ---------------------------------------------------------------------------
# This file used to be vendored from the restic repository (now
# backup-restic-push), which carried the authoritative copy. That copy is
# gone: the restic side no longer dumps databases at all — one job per script —
# so THIS is now the only implementation and the place to change it.
# ---------------------------------------------------------------------------
#
# This is NOT a standalone program: it is meant to be "source"d from a stack's
# db-dump.sh (see ../examples/ for thin wrappers). It centralises the generic
# parts that used to be copy-pasted into every dump script:
#   - creating the db-dumps/ directory,
#   - rotating/deleting old dumps (retention),
#   - timestamped dump filenames,
#   - logging in the run format of backup-docker-db.sh.
#
# The DB-specific bit (which command, which container, user/db) stays in each
# stack's db-dump.sh, which calls the dump_* helpers below.
#
# Context variables — resolved with defaults so a wrapper works BOTH standalone
# (./db-dump.sh) and when launched by backup-docker-db.sh:
#   STACK_DIR   directory of the calling db-dump.sh (the stack). Derived from the
#               caller's path when not set in the environment.
#   STACK_NAME  used in log messages and as the container name prefix. Defaults
#               to the stack directory name. backup-docker-db.sh sets this.
#   RETENTION_DAYS  days to keep dumps; set per stack in the wrapper (default 30).
#
# ${BASH_SOURCE[1]} is the file that sourced us (the wrapper), so STACK_DIR is the
# stack directory in both the standalone and the orchestrated case.
: "${STACK_DIR:=$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)}"
: "${STACK_NAME:=$(basename "$STACK_DIR")}"
# ":=" (local modification, see the header): keeps the upstream default when the
# caller says nothing, but lets backup-docker-db.sh redirect the dumps into the
# central STAGING_DIR. All dump_* helpers read DUMP_DIR at CALL time, so an
# orchestrator that loops over stacks can also re-assign it per stack.
: "${DUMP_DIR:=$STACK_DIR/db-dumps}"

# Log in the same format as backup-docker-db.sh ("<ts> [LEVEL] msg"). No log file is
# written here — backup-docker-db.sh captures this script's stdout/stderr. Logs go
# to STDERR on purpose: _resolve_container returns the container id on stdout via
# a command substitution, so its diagnostics must not pollute that channel.
log() {
  local level="$1"; shift
  printf '%s %-7s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "[${level}]" "$*" >&2
}

_dump_ts() { date +%Y-%m-%dT%H-%M-%S; }

dump_prepare() {
  # Create the dump directory and remove dumps older than RETENTION_DAYS so they
  # do not pile up forever. Call ONCE before the dump_* helpers. RETENTION_DAYS
  # is set per stack in the wrapper (default 30), KEEP_MIN likewise (default 2).
  #
  # KEEP_MIN is the part a plain "find -mtime +N -delete" gets wrong: a database
  # that has not been dumped for a while — a stack that was down, a dump that
  # kept failing — would have all its files expire on the same day and leave the
  # stack with nothing at all. The newest KEEP_MIN dumps are therefore protected
  # regardless of age. Local retention is short anyway; the actual history lives
  # in the backup repositories.
  #
  # "Newest" is decided by the timestamp IN THE FILE NAME (%Y-%m-%dT%H-%M-%S),
  # which sorts lexically exactly as it sorts chronologically. That avoids
  # GNU-only "find -printf" (this also has to work on a busybox host) and it
  # survives a copy that did not preserve mtimes.
  #
  # The protection is per NAME PREFIX, not per directory: a stack with several
  # SQLITE_FILES writes "db1-<ts>.sqlite3" and "db2-<ts>.sqlite3" side by side,
  # and keeping "the newest two files" would keep two of db2 and none of db1.
  local retention="${RETENTION_DAYS:=30}" keep="${KEEP_MIN:=2}" f removed=0

  mkdir -p "$DUMP_DIR" \
    || { log ERROR "${STACK_NAME}: cannot create dump directory $DUMP_DIR"; exit 1; }

  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    # POSIX find on the single file: prints it only if it is older than <days>.
    [[ -n "$(find "$f" -type f -mtime +"$retention" -print 2>/dev/null)" ]] || continue
    rm -f "$f" && removed=$((removed + 1))
  done < <(
    find "$DUMP_DIR" -maxdepth 1 -type f 2>/dev/null \
      | LC_ALL=C sort -r \
      | awk -v keep="$keep" '
          {
            name = $0; sub(/.*\//, "", name)
            group = name
            # Strip "-<YYYY-MM-DDTHH-MM-SS>" and whatever follows it. Written out
            # rather than with {n} intervals, which not every awk supports.
            sub(/-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]-[0-9][0-9]-[0-9][0-9].*$/, "", group)
            seen[group]++
            if (seen[group] > keep) print $0
          }'
  )

  if [[ "$removed" -gt 0 ]]; then
    log INFO "${STACK_NAME}: removed $removed dump(s) older than ${retention} days in $DUMP_DIR (keeping at least ${keep} per database)"
  else
    log INFO "${STACK_NAME}: nothing to rotate in $DUMP_DIR (retention ${retention} days, keep at least ${keep} per database)"
  fi
}

# --- container discovery & dump finalisation ---------------------------------
#
# The dump_postgres/dump_mariadb helpers no longer guess the container name from
# "${STACK_NAME}-<suffix>". Instead they resolve the target through docker
# compose run FROM THE STACK DIRECTORY, so a custom "container_name:" or project
# name no longer breaks anything and the stack's docker-compose.yml needs no
# edits. Resolution order (most explicit first):
#   DB_CONTAINER  raw container name/id, used verbatim (bypasses compose)
#   DB_SERVICE / first arg   a compose service name -> docker compose ps -q
#   auto-detect   the project's running container that looks like the engine
#                 (image name / exposed port / engine env var — so postgres
#                 derivatives like pgvecto-rs are found too)
#
# The dump is streamed to db-dumps/ ON THE HOST via "docker exec ... > file", so
# no bind mount (db-dumps/ -> /tmp/dumps) is required inside the container.

_compose() {
  # Run docker compose from the stack directory in a subshell so service ->
  # container resolution and container_name: overrides are handled by compose
  # itself, without cd-ing the caller's shell.
  ( cd "$STACK_DIR" && docker compose "$@" )
}

_resolve_container() {
  # _resolve_container <engine> [service]
  # Echoes exactly one container id on stdout, or logs an actionable error and
  # returns 1. <engine> is "postgres" or "mysql" (selects the detection signals).
  # Command substitutions are captured in their own statement and guarded with
  # "|| true" so a non-match never trips `set -e`; emptiness is then tested.
  local engine="$1" service="${2:-${DB_SERVICE:-}}"
  local cid="" ids id img img_re port env_re ports envs matches=()

  command -v docker >/dev/null 2>&1 \
    || { log ERROR "${STACK_NAME}: docker not found on the host"; return 1; }

  # 1. Raw container override — used verbatim, must be running.
  if [[ -n "${DB_CONTAINER:-}" ]]; then
    if docker inspect -f '{{.State.Running}}' "$DB_CONTAINER" 2>/dev/null | grep -qx true; then
      printf '%s\n' "$DB_CONTAINER"; return 0
    fi
    log ERROR "${STACK_NAME}: DB_CONTAINER='${DB_CONTAINER}' not found or not running"; return 1
  fi

  # 2. Explicit compose service.
  if [[ -n "$service" ]]; then
    cid="$(_compose ps -q "$service" 2>/dev/null | head -n1)" || true
    [[ -z "$cid" ]] && { log ERROR "${STACK_NAME}: compose service '${service}' has no running container in ${STACK_DIR}"; return 1; }
    printf '%s\n' "$cid"; return 0
  fi

  # 3. Auto-detect among the project's running containers. The image NAME alone
  # is unreliable: postgres derivatives (pgvecto-rs, pgvector, postgis, …) carry
  # no "postgres" in the name. So a container counts as the engine if ANY of
  # three signals match: a broadened image pattern, the engine's exposed port
  # (derivatives inherit EXPOSE 5432/3306 from the base image), or the engine's
  # telltale env var prefix.
  ids="$(_compose ps -q 2>/dev/null)" || true
  [[ -z "$ids" ]] && { log ERROR "${STACK_NAME}: no running compose containers in ${STACK_DIR} (is the stack up?)"; return 1; }

  case "$engine" in
    postgres) img_re='[Pp]ostgres|pgvecto|pgvector|postgis|timescale|citus|supabase'
              port='5432/'; env_re='^POSTGRES_' ;;
    mysql)    img_re='[Mm]aria|[Mm]ysql|percona'
              port='3306/'; env_re='^(MYSQL|MARIADB)_' ;;
    *)        log ERROR "${STACK_NAME}: unknown engine '${engine}'"; return 1 ;;
  esac

  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    img="$(docker inspect -f '{{.Config.Image}}' "$id" 2>/dev/null)" || continue
    if printf '%s' "$img" | grep -Eq "$img_re"; then matches+=("$id"); continue; fi
    ports="$(docker inspect -f '{{range $p, $v := .Config.ExposedPorts}}{{println $p}}{{end}}' "$id" 2>/dev/null)" || ports=""
    if printf '%s' "$ports" | grep -q "$port"; then matches+=("$id"); continue; fi
    envs="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$id" 2>/dev/null)" || envs=""
    if printf '%s\n' "$envs" | grep -Eq "$env_re"; then matches+=("$id"); continue; fi
  done <<< "$ids"

  if [[ "${#matches[@]}" -eq 0 ]]; then
    log ERROR "${STACK_NAME}: no ${engine} container auto-detected. Set DB_SERVICE=<service> or DB_CONTAINER=<name> in db-dump.sh."; return 1
  fi
  if [[ "${#matches[@]}" -gt 1 ]]; then
    local names; names="$(for id in "${matches[@]}"; do docker inspect -f '{{.Config.Image}}' "$id"; done | paste -sd, -)"
    log ERROR "${STACK_NAME}: multiple ${engine} containers matched (${names}). Disambiguate with DB_SERVICE=<service> in db-dump.sh."; return 1
  fi
  printf '%s\n' "${matches[0]}"
}

_finalize_dump() {
  # _finalize_dump <rc> <target> <label> <cid>
  # Because the dump is redirected on the host, a failing/aborted dump command
  # can still leave a 0-byte target behind; delete it and fail loudly rather
  # than letting an empty "dump" get backed up.
  local rc="$1" target="$2" label="$3" cid="$4"
  if [[ "$rc" -ne 0 ]]; then
    rm -f "$target"; log ERROR "${STACK_NAME}: ${label} dump failed (exit $rc) for container ${cid}"; exit 1
  fi
  if [[ ! -s "$target" ]]; then
    rm -f "$target"; log ERROR "${STACK_NAME}: ${label} dump produced an empty file — aborting (check credentials)"; exit 1
  fi
  log INFO "${STACK_NAME}: ${label} dump written: $target"
}

dump_postgres() {
  # dump_postgres [service]
  # Auto-detects the postgres container in this stack's compose project (override
  # with DB_SERVICE or DB_CONTAINER) and streams a plain-SQL dump into db-dumps/
  # on the host. No bind mount or docker-compose.yml change is required.
  #
  # Credentials are resolved INSIDE the container, trying common env vars and
  # their _FILE secret variants. Optional host overrides: DB_USER, DB_NAME,
  # DB_PASSWORD (passed in as OVR_* and taking precedence). pg_dump over the
  # local socket usually needs no password (trust/peer), so an empty password is
  # fine; PGPASSWORD/POSTGRES_PASSWORD(_FILE) are honoured if present.
  local service="${1:-}" cid ts target rc=0
  cid="$(_resolve_container postgres "$service")" || exit 1
  ts="$(_dump_ts)"; target="$DUMP_DIR/dump-${ts}.sql"
  # "|| rc=$?" keeps a failing dump from tripping `set -e` before _finalize_dump
  # can clean up the (possibly empty) target and log the failure.
  docker exec \
      -e OVR_USER="${DB_USER:-}" -e OVR_DB="${DB_NAME:-}" -e OVR_PW="${DB_PASSWORD:-}" \
      "$cid" sh -c '
        U="${OVR_USER:-}"; [ -z "$U" ] && [ -n "${POSTGRES_USER_FILE:-}" ] && U="$(cat "$POSTGRES_USER_FILE")"; [ -z "$U" ] && U="${POSTGRES_USER:-postgres}"
        D="${OVR_DB:-}";   [ -z "$D" ] && [ -n "${POSTGRES_DB_FILE:-}" ]   && D="$(cat "$POSTGRES_DB_FILE")";   [ -z "$D" ] && D="${POSTGRES_DB:-$U}"
        P="${OVR_PW:-}";   [ -z "$P" ] && P="${PGPASSWORD:-}"; [ -z "$P" ] && [ -n "${POSTGRES_PASSWORD_FILE:-}" ] && P="$(cat "$POSTGRES_PASSWORD_FILE")"; [ -z "$P" ] && P="${POSTGRES_PASSWORD:-}"
        command -v pg_dump >/dev/null 2>&1 || { echo "pg_dump not found in container" >&2; exit 127; }
        export PGPASSWORD="$P"; exec pg_dump -U "$U" "$D"
      ' > "$target" || rc=$?
  _finalize_dump "$rc" "$target" "PostgreSQL" "$cid"
}

dump_mariadb() {
  # dump_mariadb [service]
  # Like dump_postgres for MariaDB/MySQL. Prefers mariadb-dump, falls back to
  # mysqldump, and resolves the root password from MYSQL_ROOT_PASSWORD /
  # MARIADB_ROOT_PASSWORD and their _FILE variants. The password is passed via
  # MYSQL_PWD to keep it off the process arg list. --single-transaction --quick
  # gives a consistent live-DB dump. Optional host overrides: DB_USER (default
  # root), DB_NAME (single DB instead of --all-databases), DB_PASSWORD.
  local service="${1:-}" cid ts target rc=0
  cid="$(_resolve_container mysql "$service")" || exit 1
  ts="$(_dump_ts)"; target="$DUMP_DIR/dump-${ts}.sql"
  # "|| rc=$?" keeps a failing dump from tripping `set -e` before _finalize_dump
  # can clean up the (possibly empty) target and log the failure.
  docker exec \
      -e OVR_USER="${DB_USER:-}" -e OVR_DB="${DB_NAME:-}" -e OVR_PW="${DB_PASSWORD:-}" \
      "$cid" sh -c '
        U="${OVR_USER:-root}"
        P="${OVR_PW:-}"
        [ -z "$P" ] && [ -n "${MYSQL_ROOT_PASSWORD_FILE:-}" ]   && P="$(cat "$MYSQL_ROOT_PASSWORD_FILE")"
        [ -z "$P" ] && [ -n "${MARIADB_ROOT_PASSWORD_FILE:-}" ] && P="$(cat "$MARIADB_ROOT_PASSWORD_FILE")"
        [ -z "$P" ] && P="${MYSQL_ROOT_PASSWORD:-${MARIADB_ROOT_PASSWORD:-}}"
        if   command -v mariadb-dump >/dev/null 2>&1; then DUMP=mariadb-dump
        elif command -v mysqldump   >/dev/null 2>&1; then DUMP=mysqldump
        else echo "neither mariadb-dump nor mysqldump found in container" >&2; exit 127; fi
        [ -n "$P" ] && export MYSQL_PWD="$P"
        if [ -n "${OVR_DB:-}" ]; then exec "$DUMP" -u "$U" --single-transaction --quick "$OVR_DB"
        else exec "$DUMP" -u "$U" --single-transaction --quick --all-databases; fi
      ' > "$target" || rc=$?
  _finalize_dump "$rc" "$target" "MariaDB/MySQL" "$cid"
}

dump_sqlite() {
  # dump_sqlite <path-to-db-file>
  # SQLite has no DB server: the database is a plain file on the host, so the
  # dump runs ENTIRELY OUTSIDE the container with the host's sqlite3 binary. The
  # online ".backup" command produces a consistent binary copy even while the app
  # still has the DB open. The target keeps the original filename plus a timestamp
  # (e.g. database.sqlite -> database-2026-06-07T10-23-00.sqlite).
  local db_file="$1" name ts target
  command -v sqlite3 >/dev/null 2>&1 \
    || { log ERROR "${STACK_NAME}: sqlite3 not found on the host"; exit 1; }
  [[ -f "$db_file" ]] \
    || { log ERROR "${STACK_NAME}: database file not found: $db_file"; exit 1; }
  name="$(basename "$db_file")"
  ts="$(_dump_ts)"
  target="$DUMP_DIR/${name%.*}-$ts.${name##*.}"
  if sqlite3 "$db_file" ".backup '$target'"; then
    log INFO "${STACK_NAME}: SQLite backup written: $target"
  else
    log ERROR "${STACK_NAME}: sqlite3 .backup failed for $db_file"; exit 1
  fi
}
