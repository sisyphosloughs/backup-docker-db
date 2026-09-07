#!/usr/bin/env bash
#
# docker-db-dump.sh — script 1 of the pull-backup architecture.
#
# Creates the database dumps of all configured Docker stacks LOCALLY on the
# SOURCE host and publishes them under STAGING_DIR. It never talks to a backup
# target: no restic, no repository credential, no outbound connection except the
# Telegram notification. The BACKUP host pulls STAGING_DIR read-only and runs
# restic there. That separation is the whole point of the split — a compromised
# SOURCE can neither alter existing backups nor write into the backup zone — and
# must not be weakened here ("push it directly, it's simpler" is not an option).
#
# The only coupling to the pull side is one narrow contract: the marker file
# STAGING_DIR/.complete. It is written atomically at the end of a run and ONLY
# when every configured stack was dumped without a single error. A missing or
# stale marker tells the pull side: do not use this staging directory.
#
# Nothing is hard-coded here; every path, stack and switch comes from:
#   global.conf         run-wide switches (paths, retention, Telegram, …)
#   stacks/<name>.conf  one file per stack to dump — a new stack needs no
#                       change to this script
#   lib/db-dump-lib.sh  vendored dump helpers (container autodetection,
#                       credential resolution, retention) — see its header
#   lib/runlib/         the shared run skeleton (log file, error account, lock,
#                       configuration loader, summary, notification, marker),
#                       a git submodule shared with the other backup scripts
# all relative to this script's directory. Needs docker access (run as root).
# See README.md.

set -uo pipefail

# ---------------------------------------------------------------------------
# 1. Initialisation
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Per-stack records, index-parallel with runlib's INSTANCE_NAMES/INSTANCE_CONFS.
# They are appended by validate_stack() exactly when it accepts a stack, so the
# indices stay aligned; dump_one_stack() reads them by index.
STACK_ENGINES=()
STACK_PATHS=()

# Which external programs the configured stacks actually need (set by
# validate_stack, evaluated by check_binaries) — a host without SQLite stacks
# should not be nagged about a missing sqlite3.
NEED_DOCKER=0
NEED_SQLITE=0

# ---------------------------------------------------------------------------
# 2. Command line
#
# Parsed before anything else so "--help" neither reads a configuration nor
# creates a log file.
# ---------------------------------------------------------------------------

SELECTED_STACKS=()
ACTION="run"

usage() {
  cat <<'EOF'
Usage: docker-db-dump.sh [options]

Dumps the databases of the stacks configured in stacks/*.conf into STAGING_DIR
and writes the completion marker when every one of them succeeded.

Options:
  -s, --stack NAME   Dump only this stack (repeatable). A partial run NEVER
                     writes the completion marker — use it for testing a new
                     stacks/<name>.conf, not for scheduled runs.
  -l, --list         List the configured stacks and exit.
  -h, --help         Show this help and exit.

Exit code: 0 only if the run was completely error-free.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -l|--list) ACTION="list"; shift ;;
    -s|--stack)
      [[ $# -ge 2 ]] || { echo "FATAL: --stack requires a stack name" >&2; exit 2; }
      SELECTED_STACKS+=("$2"); shift 2 ;;
    --stack=*) SELECTED_STACKS+=("${1#*=}"); shift ;;
    *) echo "FATAL: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# 3. Libraries
#
# Order matters. runlib first: it provides log_info/log_error (stdout + log
# file) and everything the run skeleton needs. db-dump-lib.sh second, because it
# owns the bare log() that its own helpers use for their stderr-only
# diagnostics — see the header of runlib/log.sh for why the two channels must
# stay apart.
# ---------------------------------------------------------------------------

RUNLIB="$SCRIPT_DIR/lib/runlib/runlib.sh"
DB_DUMP_LIB="$SCRIPT_DIR/lib/db-dump-lib.sh"
for lib_file in "$RUNLIB" "$DB_DUMP_LIB"; do
  [[ -r "$lib_file" ]] || {
    echo "FATAL: library not readable: $lib_file" >&2
    echo "       (lib/runlib is a git submodule — run 'git submodule update --init')" >&2
    exit 1
  }
done
# shellcheck source=lib/runlib/runlib.sh
source "$RUNLIB"

# db-dump-lib.sh derives STACK_DIR/STACK_NAME/DUMP_DIR from the sourcing file at
# source time. Pre-set them so that derivation is a harmless no-op: the real
# values are assigned per stack in dump_one_stack(), and every dump_* helper
# reads them at call time.
STACK_DIR="$SCRIPT_DIR"
STACK_NAME="-"
DUMP_DIR="$SCRIPT_DIR"
# shellcheck source=lib/db-dump-lib.sh
source "$DB_DUMP_LIB"

# ---------------------------------------------------------------------------
# 4. Log file
#
# Created BEFORE the configuration is read, so configuration errors also end up
# in a log file instead of vanishing on stderr. Depends only on SCRIPT_DIR.
# ---------------------------------------------------------------------------

LOG_DIR="$SCRIPT_DIR/logs"
run_init "$LOG_DIR" "db-dump" \
  || { echo "FATAL: cannot create the log file in $LOG_DIR" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 5. Configuration
# ---------------------------------------------------------------------------

GLOBAL_CONF="$SCRIPT_DIR/global.conf"
[[ -f "$GLOBAL_CONF" ]] \
  || fatal "Global configuration not found: $GLOBAL_CONF (copy global.conf.example and adjust it)"
# shellcheck source=/dev/null
source "$GLOBAL_CONF"

# Optional values: ":=" only assigns when unset or empty, so anything set in
# global.conf always wins.
: "${STACKS_BASE:=}"
: "${STACKS_DIR:=$SCRIPT_DIR/stacks}"
: "${MARKER_NAME:=.complete}"
: "${DUMP_RETENTION_DAYS:=7}"
: "${LOG_RETENTION_DAYS:=64}"
: "${STAGING_MODE:=0750}"
: "${STAGING_GROUP:=}"
: "${DUMP_UMASK:=0027}"
: "${DOCKER_STOP_TIMEOUT:=20}"
: "${EXTRA_PATH:=}"

[[ -n "${STAGING_DIR:-}" ]] || fatal "STAGING_DIR not set (global.conf)"
MARKER_PATH="${STAGING_DIR%/}/${MARKER_NAME}"

# ---------------------------------------------------------------------------
# 5b. What this run calls things
#
# runlib runs the same skeleton for every script of the family; these are the
# words that keep THIS script's log and notification its own.
# ---------------------------------------------------------------------------

# shellcheck disable=SC2034  # every name here is read by lib/runlib, not below.
{
  RUN_WHAT="DB dumps"
  RUN_LOG_NAME="DB dump run"
  RUN_UNIT="Stacks"
  RUN_OK_VERB="DB dump successful"
  RUN_ABORT_HINT="The staging directory is not consistent; the pull side must not use it."
  RUN_USES_MARKER=1
  INSTANCE_LABEL="Stack"
  INSTANCE_LABEL_LC="stack"
  INSTANCE_OPT="--stack"
  # Set by the marker cascade below and rendered by runlib's run_finish.
  MARKER_NOTE="not written"
}

# Telegram credentials: from TELEGRAM_CONF when global.conf points at one,
# otherwise from global.conf itself.
notify_init

# ---------------------------------------------------------------------------
# 6. trap handler
#
# Registered as soon as the Telegram credentials are known, so a configuration
# error from here on also raises an alarm instead of failing silently under
# cron. Nothing has to be rolled back at this level: a stack whose services were
# stopped for a quiesced dump restarts them in its own EXIT trap (see
# dump_one_stack).
#
# On a signal, stop for real instead of resuming where the run was interrupted:
# a half-dumped staging directory must not continue towards a completion marker.
# ---------------------------------------------------------------------------

run_traps

# ---------------------------------------------------------------------------
# 7. Helper functions
# ---------------------------------------------------------------------------

prepare_staging_dir() {
  # prepare_staging_dir <dir> — create a staging directory and make it readable
  # for the pull side. Returns 1 on failure WITHOUT logging: it is called both
  # from the run level and from inside the per-stack subshell, and those two log
  # through different channels — so the call site reports the failure.
  local dir="$1"
  mkdir -p "$dir" || return 1
  chmod "$STAGING_MODE" "$dir" || return 1
  if [[ -n "$STAGING_GROUP" ]]; then
    chgrp "$STAGING_GROUP" "$dir" || return 1
    # setgid: every dump created later inherits the group, so the read-only pull
    # user can read it without this script chasing each new file with a chgrp.
    chmod g+s "$dir" || return 1
  fi
  return 0
}

# shellcheck disable=SC2034  # DB_*/SQLITE_FILES are read by db-dump-lib.sh and
# by the stack configurations sourced on top of them, not by this function.
reset_stack_vars() {
  # reset_stack_vars <name> — every per-stack variable, back to its default.
  #
  # Called in two places: by runlib's loader before each stacks/<name>.conf is
  # sourced, and again inside the per-stack subshell before the same file is
  # re-sourced. So a value from one file never leaks into the next, and both
  # places start from the same documented state.
  #
  # These are plain globals ON PURPOSE (not "local"): the dump_* helpers of
  # db-dump-lib.sh read them by name.
  #
  # STACK_DIR is pre-filled with the default derived from the name, so the
  # configuration can already refer to "$STACK_DIR" (and still override it
  # outright).
  local name="${1:-}"
  ENGINE=""
  STACK_DIR="${STACKS_BASE:+${STACKS_BASE%/}/$name}"
  ENABLED="true"
  RETENTION_DAYS=""
  DUMP_SCRIPT=""
  DB_SERVICE=""
  DB_CONTAINER=""
  DB_USER=""
  DB_NAME=""
  DB_PASSWORD=""
  SQLITE_FILES=()
  STOP_SERVICES=()
  STOPPED_SERVICES=()
}

validate_stack() {
  # validate_stack <name> <conf> — runlib's per-object hook. The configuration
  # has been sourced at this point, so ENGINE/STACK_DIR carry what it said.
  #
  # A configuration that cannot be used is an ERROR, not a silent skip: it ends
  # up in ERRORS and thus suppresses the completion marker. Only an explicit
  # ENABLED=false is a deliberate skip (runlib handles that).
  local name="$1" conf="$2"

  case "$ENGINE" in
    postgres)      NEED_DOCKER=1 ;;
    mariadb|mysql) NEED_DOCKER=1 ;;
    sqlite)        NEED_SQLITE=1 ;;
    # custom: the stack's own db-dump.sh decides what it needs, so no
    # requirement is inferred here.
    custom)        ;;
    "")  log_error "Stack '$name' ($conf): ENGINE not set — stack skipped"; return 1 ;;
    *)   log_error "Stack '$name': unknown ENGINE '$ENGINE' (postgres|mariadb|sqlite|custom) — stack skipped"; return 1 ;;
  esac

  if [[ -z "$STACK_DIR" ]]; then
    log_error "Stack '$name': neither STACK_DIR (stack config) nor STACKS_BASE (global.conf) is set — stack skipped"
    return 1
  fi
  if [[ ! -d "$STACK_DIR" ]]; then
    log_error "Stack '$name': stack directory does not exist: $STACK_DIR — stack skipped"
    return 1
  fi

  STACK_ENGINES+=("$ENGINE")
  STACK_PATHS+=("$STACK_DIR")
  instances_record "${STAGING_DIR%/}/$name" "$name ($ENGINE)"
  log_info "Stack '$name': engine $ENGINE, directory $STACK_DIR, retention ${RETENTION_DAYS:-$DUMP_RETENTION_DAYS} days"
  return 0
}

check_binaries() {
  # Report the availability of the required programs at the very start, so a
  # missing or mislocated binary is obvious in the log instead of surfacing as a
  # cryptic failure halfway through. Which ones are required follows from the
  # configured engines (see validate_stack).
  log_info "--- Checking programs ---"
  local p

  if [[ "$NEED_DOCKER" -eq 1 ]]; then
    if p="$(command -v docker 2>/dev/null)"; then
      if docker compose version >/dev/null 2>&1; then
        log_info "docker found: $p (Compose V2 plugin available)"
      else
        log_error "docker found ($p), but the Compose V2 plugin ('docker compose') is not available — containers cannot be resolved"
      fi
    else
      log_error "docker not found — no container can be dumped. Set EXTRA_PATH in global.conf if docker lives outside the (cron) PATH."
    fi
  fi

  if [[ "$NEED_SQLITE" -eq 1 ]]; then
    if p="$(command -v sqlite3 2>/dev/null)"; then
      log_info "sqlite3 found: $p"
    else
      log_error "sqlite3 not found on the host, but SQLite stacks are configured"
    fi
  fi

  notify_check_binaries
}

# --- per-stack dump ---------------------------------------------------------

stop_stack_services() {
  # Optional per-stack switch: stop the listed compose services so nothing
  # writes to the database while it is read. Default is empty, because a plain
  # SQL dump is already consistent (pg_dump reads a REPEATABLE READ snapshot,
  # MariaDB is dumped with --single-transaction).
  #
  # It is worth setting only where the dump method has no online consistency:
  # MyISAM/Aria tables (--single-transaction covers InnoDB only), SQLite behind
  # a writer that never pauses, or an ENGINE=custom store that is copied as
  # files. It does NOT produce a matching file+database state — the stack's
  # files are pulled by the backup host later, with the application running
  # again, so that would need an atomic capture inside this stopped window.
  #
  # The database service itself must NOT be listed for postgres/mariadb — it has
  # to be running to be dumped.
  [[ "${#STOP_SERVICES[@]}" -gt 0 ]] || return 0
  log INFO "${STACK_NAME}: stopping services for a quiesced dump: ${STOP_SERVICES[*]}"
  if _compose stop --timeout "$DOCKER_STOP_TIMEOUT" "${STOP_SERVICES[@]}"; then
    STOPPED_SERVICES=("${STOP_SERVICES[@]}")
    return 0
  fi
  log ERROR "${STACK_NAME}: services could not be stopped (${STOP_SERVICES[*]}) — no dump taken"
  return 1
}

restart_stack_services() {
  # Called from the subshell's EXIT trap, so the services come back up on every
  # path out — including the "exit 1" that the dump_* helpers use to report a
  # failed dump.
  [[ "${#STOPPED_SERVICES[@]}" -gt 0 ]] || return 0
  local services=("${STOPPED_SERVICES[@]}")
  STOPPED_SERVICES=()
  if _compose start "${services[@]}"; then
    log INFO "${STACK_NAME}: services started again: ${services[*]}"
    return 0
  fi
  log ERROR "${STACK_NAME}: services could NOT be started again (${services[*]}) — manual intervention needed"
  return 1
}

_stack_exit_trap() {
  local rc=$?
  # A stack whose services could not be restarted counts as failed even if its
  # dump itself worked: the run must not end up reporting success, and above all
  # must not write the completion marker, while a container stays down.
  restart_stack_services || rc=1
  exit "$rc"
}

run_custom_dump() {
  # ENGINE=custom — hand over to the stack's own db-dump.sh (the thin wrapper
  # pattern from the reference repository, see examples/db-dump.custom.sh). The
  # environment tells it where to write and which library to use, so the same
  # wrapper also works standalone.
  local script="${DUMP_SCRIPT:-$STACK_DIR/db-dump.sh}"
  if [[ ! -x "$script" ]]; then
    log ERROR "${STACK_NAME}: custom dump script not found or not executable: $script"
    return 1
  fi
  log INFO "${STACK_NAME}: running custom dump script: $script"
  STACK_NAME="$STACK_NAME" STACK_DIR="$STACK_DIR" DUMP_DIR="$DUMP_DIR" \
  RETENTION_DAYS="$RETENTION_DAYS" DB_DUMP_LIB="$DB_DUMP_LIB" \
    "$script"
}

dump_one_stack() {
  # dump_one_stack <name> <conf> <index> — runlib's worker.
  #
  # Called on the LEFT side of a pipeline, i.e. in a SUBSHELL — deliberately:
  # the helpers of db-dump-lib.sh end a failed dump with "exit 1", which has to
  # end THIS stack and not the whole run.
  #
  # Inside here, logging therefore goes through the library's log() (stderr,
  # captured by that pipe); log_info/log_error belong to the run level, would be
  # written to the log file a second time by the pipe, and could not report
  # anything back across the subshell boundary anyway.
  local name="$1" conf="$2" idx="$3" db_file rc=0
  local stack_dir="${STACK_PATHS[$idx]}"

  reset_stack_vars "$name"

  # Context for db-dump-lib.sh, set BEFORE the configuration is sourced so it
  # can refer to "$STACK_DIR" (SQLITE_FILES, DUMP_SCRIPT). The value was already
  # resolved by the loader, including a STACK_DIR the configuration sets itself.
  # DUMP_DIR is what turns the reference repo's "dumps live next to their stack"
  # into this concept's central staging tree.
  STACK_NAME="$name"
  STACK_DIR="$stack_dir"
  DUMP_DIR="${STAGING_DIR%/}/$name"

  # shellcheck source=/dev/null
  source "$conf" || { log ERROR "${name}: cannot read $conf"; exit 1; }

  # Re-pin the context: a stack configuration may legitimately assign STACK_DIR
  # (same value as above), but none of these may end up different from what the
  # run level assumes — DUMP_DIR above all, since a stack writing outside the
  # staging tree would be missing from the backup without anyone noticing.
  STACK_NAME="$name"
  STACK_DIR="$stack_dir"
  DUMP_DIR="${STAGING_DIR%/}/$name"
  RETENTION_DAYS="${RETENTION_DAYS:-$DUMP_RETENTION_DAYS}"

  prepare_staging_dir "$DUMP_DIR" \
    || { log ERROR "${name}: cannot prepare the staging directory $DUMP_DIR"; exit 1; }

  trap _stack_exit_trap EXIT
  stop_stack_services || exit 1

  # Creates DUMP_DIR (already there) and rotates dumps older than
  # RETENTION_DAYS. Local retention is deliberately short — the actual history
  # lives in the restic repositories on the backup side.
  dump_prepare

  case "$ENGINE" in
    postgres)
      # Container autodetection and credential resolution come from the library;
      # DB_SERVICE/DB_CONTAINER/DB_USER/DB_NAME/DB_PASSWORD were sourced from the
      # stack configuration above and are read from the environment there.
      dump_postgres || rc=$?
      ;;
    mariadb|mysql)
      dump_mariadb || rc=$?
      ;;
    sqlite)
      if [[ "${#SQLITE_FILES[@]}" -eq 0 ]]; then
        log ERROR "${name}: ENGINE=sqlite, but SQLITE_FILES is empty"
        exit 1
      fi
      for db_file in "${SQLITE_FILES[@]}"; do
        [[ -n "$db_file" ]] || continue
        dump_sqlite "$db_file" || rc=$?
      done
      ;;
    custom)
      run_custom_dump || rc=$?
      ;;
    *)
      log ERROR "${name}: unknown ENGINE '$ENGINE'"
      rc=1
      ;;
  esac

  # Exit EXPLICITLY, do not just fall off the end. This function runs in a
  # PIPELINE subshell, and there an EXIT trap is not reliably executed when the
  # body simply ends (bash 3.2 skips it) — the stack's services would then never
  # be started again. With an explicit exit the trap runs on every version.
  exit "$rc"
}

# ---------------------------------------------------------------------------
# 8. Start
# ---------------------------------------------------------------------------

log_info "Starting DB dump run on $HOSTNAME_SHORT"
log_rotate "$LOG_DIR" "db-dump" "$LOG_RETENTION_DAYS"

# Cron starts with a minimal PATH, and on some hosts (e.g. a NAS) docker or
# sqlite3 live somewhere like /volume1/opt/bin. EXTRA_PATH puts them in reach —
# for this script and for db-dump-lib.sh, which calls docker/sqlite3 by name.
if [[ -n "$EXTRA_PATH" ]]; then
  PATH="$EXTRA_PATH:$PATH"
  export PATH
  log_info "PATH extended by EXTRA_PATH: $EXTRA_PATH"
fi

instances_load "$STACKS_DIR" reset_stack_vars validate_stack \
  "${SELECTED_STACKS[@]+"${SELECTED_STACKS[@]}"}"

if [[ "$ACTION" == "list" ]]; then
  log_info "--- Configured stacks (${#INSTANCE_NAMES[@]}) ---"
  for idx in "${!INSTANCE_NAMES[@]}"; do
    log_plain "  ${INSTANCE_NAMES[$idx]}  engine=${STACK_ENGINES[$idx]}  dir=${STACK_PATHS[$idx]}  staging=${STAGING_DIR%/}/${INSTANCE_NAMES[$idx]}"
  done
  run_end 0
fi

check_binaries

acquire_lock || run_end 1

# Dumps are written with 0640 / directories 0750 (DUMP_UMASK): a SQL dump holds
# the entire database, so it must not be world-readable just because the pull
# user needs to read it — that user gets in via STAGING_GROUP. Set after the log
# file was created, which stays world-readable on purpose.
umask "$DUMP_UMASK"

prepare_staging_dir "$STAGING_DIR" \
  || fatal "Cannot prepare the staging directory: $STAGING_DIR"
log_info "Staging directory: $STAGING_DIR (mode $STAGING_MODE${STAGING_GROUP:+, group $STAGING_GROUP})"

# Staging inside the stack tree would make the pull side see every dump twice
# (once in the stack directory it may also pull, once in staging) and would put
# the dumps back into the data set they were extracted from. is_inside (runlib)
# normalises both paths first, so a relative path or a "/../" cannot slip past.
if [[ -n "$STACKS_BASE" ]] && is_inside "$STAGING_DIR" "$STACKS_BASE"; then
  log_warn "STAGING_DIR lies inside STACKS_BASE ($STACKS_BASE) — the pull side would see the dumps twice"
fi

if [[ "${#SELECTED_STACKS[@]}" -gt 0 ]]; then
  log_warn "Partial run (--stack ${SELECTED_STACKS[*]}) — the completion marker will NOT be written"
fi

# ---------------------------------------------------------------------------
# 9. Dumps
# ---------------------------------------------------------------------------

log_info "--- DB dumps ---"
run_worker_loop dump_one_stack

# ---------------------------------------------------------------------------
# 10. Completion marker
#
# MARKER_NOTE is the one value this section produces: runlib's run_finish puts
# it into the closing log line and the notification.
# ---------------------------------------------------------------------------

# shellcheck disable=SC2034  # MARKER_NOTE is read by lib/runlib's run_finish.
if [[ "${#ERRORS[@]}" -gt 0 ]]; then
  # _log_emit, not log_error: every one of those errors is already recorded —
  # this line only states the consequence and must not inflate the count.
  _log_emit "ERROR" "Run had ${#ERRORS[@]} error(s) — completion marker NOT written; the pull side must not use this staging directory"
  MARKER_NOTE="NOT written — the pull side must not use this staging directory"
elif [[ "${#SELECTED_STACKS[@]}" -gt 0 ]]; then
  log_info "Partial run — completion marker deliberately not written (an existing one is left untouched)"
  MARKER_NOTE="not written (partial run) — an existing marker still applies"
else
  if write_marker "$MARKER_PATH" "$STAGING_GROUP" "docker-db-dump" \
       "stacks_ok=${#OK_INSTANCES[@]}" \
       "stacks_total=${#INSTANCE_NAMES[@]}" \
       "dump_bytes=$TOTAL_BYTES"; then
    MARKER_NOTE="written ($MARKER_PATH)"
  else
    MARKER_NOTE="NOT written — writing it failed"
  fi
fi

# ---------------------------------------------------------------------------
# 11. Completion
# ---------------------------------------------------------------------------

run_finish
