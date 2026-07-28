# shellcheck shell=bash
#
# common-lib.sh — run-level helpers shared by the pull-backup scripts: the
# per-run log file, the Telegram notification and a few formatting utilities.
#
# This is NOT a standalone program: source it at the top of a script. It is the
# single sourceable library the concept asks for — the dump side
# (docker-db-dump.sh on SOURCE) and the pull/restic side on BACKUP use the same
# code instead of each carrying a copy.
#
# Deliberately absent: a bare log(). lib/db-dump-lib.sh brings its own,
# stderr-only log() and both libraries end up in the SAME shell. Keeping the
# names apart is not cosmetic: db-dump-lib.sh returns container ids through
# stdout ("cid=$(_resolve_container …)"), so its diagnostics must stay on
# stderr, while the run-level messages here go to stdout AND the log file.
# Hence log_info/log_error/… here and log() there.
#
# Provided/used across the two libraries (read at call time):
#   LOG_FILE   set by log_init; every message is appended here
#   ERRORS     array, appended to by log_error — drives the run's summary,
#              its exit code and (for the dump side) whether the completion
#              marker may be written at all

# Until log_init runs, messages go to the terminal only instead of tripping
# "set -u" or creating a stray file.
LOG_FILE="${LOG_FILE:-/dev/null}"
ERRORS=()

log_init() {
  # log_init <log-dir> <prefix> — create the log directory and this run's log
  # file ("<prefix>-<timestamp>.log", one per run) and set LOG_FILE / RUN_TS.
  # Returns 1 without logging (there is no log yet) if that is not possible;
  # the caller has to fall back to stderr.
  local dir="$1" prefix="$2"
  mkdir -p "$dir" || return 1
  RUN_TS="$(date +%Y-%m-%dT%H-%M-%S)"
  LOG_FILE="$dir/${prefix}-${RUN_TS}.log"
  touch "$LOG_FILE" || return 1
  # The script runs as root, so the log would default to root:root 0600 and be
  # unreadable for the normal user (and thus not viewable/syncable). Logs carry
  # paths, sizes and stack names — no secrets — so make them world-readable.
  chmod 644 "$LOG_FILE" 2>/dev/null || true
}

log_rotate() {
  # log_rotate <log-dir> <prefix> <days> — the script keeps its own logs
  # bounded, so no logrotate configuration is needed on the host.
  local dir="$1" prefix="$2" days="$3"
  [[ -d "$dir" ]] || return 0
  find "$dir" -maxdepth 1 -type f -name "${prefix}-*.log" -mtime +"$days" \
    -delete 2>/dev/null
  return 0
}

_log_emit() {
  # Format as in restic-backup.sh: "<ts> [LEVEL] msg", padded to width 7 so the
  # messages line up. Written to stdout and appended to the log file in one go.
  local level="$1"; shift
  printf '%s %-7s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "[${level}]" "$*" \
    | tee -a "$LOG_FILE"
}

log_info() { _log_emit "INFO" "$@"; }

# A warning is worth seeing but does NOT make the run fail — unlike log_error it
# is not recorded in ERRORS.
log_warn() { _log_emit "WARN" "$@"; }

log_error() {
  _log_emit "ERROR" "$@"
  ERRORS+=("$*")
}

# Continuation/detail line without a level prefix (lists in the summary).
log_plain() { printf '%s\n' "$*" | tee -a "$LOG_FILE"; }

# Fatal problem during initialisation: log it and give up. The caller's EXIT
# trap turns this into the "aborted" notification once it is registered.
fatal() {
  _log_emit "ERROR" "$@"
  exit 1
}

log_tail() {
  # log_tail [lines] — tail of the current log, for the notification body.
  tail -n "${1:-50}" "$LOG_FILE" 2>/dev/null
}

telegram_configured() {
  [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" \
     && "${TELEGRAM_BOT_TOKEN}" != "xxx" && "${TELEGRAM_CHAT_ID}" != "xxx" ]]
}

telegram_send() {
  # telegram_send <text> — credentials come from the global config; leaving them
  # empty (or at "xxx") disables notifications without any other change.
  local text="$1"
  if ! telegram_configured; then
    log_info "Telegram not configured, notification skipped"
    return 0
  fi
  # Telegram limit: 4096 characters.
  text="${text:0:4096}"
  if ! curl -s --max-time 30 \
      -o /dev/null \
      "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
      --data-urlencode "text=${text}"; then
    # Not log_error: a failed notification must not itself flip the run's
    # result (and the message reporting it has already been composed).
    _log_emit "ERROR" "Telegram notification could not be sent"
  fi
}

contains() {
  # contains <needle> <haystack...> — 0 if <needle> is among the arguments.
  local needle="$1"; shift
  local x
  for x in "$@"; do
    [[ "$x" == "$needle" ]] && return 0
  done
  return 1
}

is_truthy() {
  case "${1:-false}" in
    1|true|TRUE|True|yes|YES|Yes|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

human_duration() {
  # Seconds -> "4m32s"
  local secs="$1"
  printf '%dm%02ds' "$((secs / 60))" "$((secs % 60))"
}

human_bytes() {
  # Bytes -> "234 MB"
  local b="${1:-0}"
  # LC_ALL=C so the ".1f" decimal uses a dot (not a comma) regardless of locale.
  LC_ALL=C awk -v b="$b" 'BEGIN {
    split("B KB MB GB TB PB", u, " ");
    i = 1;
    while (b >= 1024 && i < 6) { b /= 1024; i++ }
    if (i == 1) printf "%d %s", b, u[i];
    else printf "%.1f %s", b, u[i];
  }'
}

bytes_newer_than() {
  # bytes_newer_than <dir> <reference-file> — total size of the files that
  # <dir> gained since <reference-file> was touched, i.e. what THIS run
  # produced. Always prints a number. Uses only POSIX find predicates so it
  # also works on a busybox host; "wc -c" per file (there are a handful) avoids
  # the "total" line that a single multi-file wc would add.
  local dir="$1" ref="$2"
  if [[ ! -d "$dir" || ! -e "$ref" ]]; then
    printf '0'
    return 0
  fi
  find "$dir" -maxdepth 1 -type f -newer "$ref" -exec wc -c {} \; 2>/dev/null \
    | awk '{ s += $1 } END { printf "%d", s + 0 }'
}
