#!/usr/bin/env bash
#
# Example db-dump.sh for a stack with ENGINE="custom".
#
# Copy into the stack directory as "db-dump.sh", make it executable (chmod +x)
# and point a stacks/<name>.conf at it with ENGINE="custom" (the default path is
# "$STACK_DIR/db-dump.sh", so nothing else is needed there).
#
# Use this escape hatch when the four built-in engines do not fit: several
# databases of different types in one stack, an engine without a dump_* helper
# (MongoDB, InfluxDB, …), an application-specific "occ export" before the SQL
# dump, and so on. Everything else — a plain postgres/mariadb/sqlite stack — is
# a two-line stacks/<name>.conf and needs no script at all.
#
# The generic logic (dump directory, retention, timestamps, logging, container
# autodetection) lives in lib/db-dump-lib.sh; this script only supplies the
# DB-specific call. docker-db-dump.sh passes the environment below, so the same
# file also works standalone (./db-dump.sh) — it then falls back to the stack's
# own db-dumps/ directory.

set -euo pipefail

# Set by docker-db-dump.sh. The standalone default is for a manual run; adjust
# it to where you placed this repository.
DB_DUMP_LIB="${DB_DUMP_LIB:-/opt/backup-docker-db/lib/db-dump-lib.sh}"

# DUMP_DIR is what puts the dumps into the central staging directory
# (STAGING_DIR/<stack>). Unset — i.e. standalone — the library falls back to
# "$STACK_DIR/db-dumps", exactly as in the reference repository. Do NOT assign
# it unconditionally here, or a run from docker-db-dump.sh would write past the
# staging directory and the backup would silently miss this stack.

# How many days each dump is kept. docker-db-dump.sh passes the stack's
# retention; the value here only applies to a standalone run.
# shellcheck disable=SC2034  # read by dump_prepare in the sourced library
RETENTION_DAYS="${RETENTION_DAYS:-30}"

# shellcheck source=../lib/db-dump-lib.sh
source "$DB_DUMP_LIB"

dump_prepare

# --- the actual dumps -------------------------------------------------------
# Every helper of the library is available here:
#
#   dump_postgres [service]   PostgreSQL (autodetected or pinned)
#   dump_mariadb  [service]   MariaDB/MySQL
#   dump_sqlite   <file>      SQLite file on the host
#
# and the overrides DB_SERVICE / DB_CONTAINER / DB_USER / DB_NAME / DB_PASSWORD
# apply to the next dump_* call. Example — two databases in one stack:

# shellcheck disable=SC2034  # DB_SERVICE is read by dump_* in the sourced library
DB_SERVICE="postgres"
dump_postgres

# shellcheck disable=SC2034
DB_SERVICE="mariadb"
dump_mariadb

# For anything the library does not cover, write into "$DUMP_DIR" yourself and
# fail loudly (exit non-zero) if it does not work — docker-db-dump.sh reports
# this stack as failed and then does NOT write the completion marker, which is
# what keeps the backup side from picking up an incomplete staging directory.
#
# ts="$(date +%Y-%m-%dT%H-%M-%S)"
# docker exec my_mongo mongodump --archive --gzip > "$DUMP_DIR/mongo-${ts}.gz"
# ----------------------------------------------------------------------------
