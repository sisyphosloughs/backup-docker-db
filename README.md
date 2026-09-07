# docker-db-dump

Creates the database dumps of Docker stacks **locally on the host they run on**
and publishes them in a staging directory that a backup host pulls read-only.

This is **script 1 of a two-part pull-backup architecture**:

| Role | Runs | Does |
|---|---|---|
| `SOURCE` | **this script** | dumps its databases into `STAGING_DIR`, writes a completion marker |
| `BACKUP` | the pull/restic script | pulls `STAGING_DIR` read-only and backs it up with restic |

The two scripts are coupled by exactly **one narrow contract**: the marker file
`STAGING_DIR/.complete`. Beyond that they know nothing about each other — this
script has no restic, no repository credential and no idea a backup host exists.

## The security contract

`SOURCE` gets **no write credential to any backup target**. It only ever creates
local dumps; `BACKUP` fetches them read-only. A compromised `SOURCE` can
therefore neither alter existing backups nor write into the backup environment.
That separation is the entire purpose of splitting the job in two and must not
be weakened anywhere — no "let's just push it directly, it's simpler".

## Files

```
<location>/
├── docker-db-dump.sh          # the script (identical on all hosts)
├── global.conf                # host-specific global config (from global.conf.example)
├── stacks/                    # one *.conf per stack whose database is dumped
│   ├── stacks.conf.example    # template for a stack
│   └── <name>.conf            # e.g. nextcloud.conf, immich.conf
├── lib/
│   ├── db-dump-lib.sh         # vendored dump helpers (see "Relationship to restic-docker-backup")
│   └── runlib/                # shared run skeleton — git submodule, see below
├── examples/
│   └── db-dump.custom.sh      # template for a stack with ENGINE="custom"
└── logs/                      # one log file per run (auto-rotated), created by the script
```

The script determines its own location at runtime; all paths derive from it, so
the location is freely choosable (e.g. `/opt/docker-db-dump`).


## The shared library

The per-run log file, the error account that decides the exit code, the flock,
the `stacks/*.conf` loader, the summary and the Telegram notification are not
implemented here. They live in
[runlib](https://github.com/sisyphosloughs/runlib) and are pulled in as a git
submodule at `lib/runlib/`, so every script of the family runs the same code and
a log line means the same thing no matter which one produced it. It replaced the
copy of `lib/common-lib.sh` that used to sit here.

What stays in this script is what is actually about dumping databases: the CLI,
the engine dispatch, `STOP_SERVICES`, the staging directory and its permissions,
and `lib/db-dump-lib.sh`. The wording of the log and the notification stays this
script's own through the variables runlib reads (`RUN_WHAT`, `INSTANCE_LABEL`, …).

A fresh clone needs `git clone --recurse-submodules`; an existing one
`git submodule update --init`. To move to a newer runlib:

```bash
git submodule update --remote lib/runlib
git add lib/runlib && git commit -m "runlib: update"
```

## What a run does

1. Read `global.conf` and every `stacks/*.conf`, validate them, check that the
   programs the configured engines need are actually there.
2. Take a concurrency lock (`flock`), so two overlapping cron runs cannot write
   into the same staging directory.
3. For each stack, in order:
   - optionally stop the compose services listed in `STOP_SERVICES`,
   - delete dumps older than `RETENTION_DAYS`,
   - write the dump to `STAGING_DIR/<stack>/dump-<timestamp>.sql`,
   - start the stopped services again (on **every** exit path, including a
     failed dump).
4. Write `STAGING_DIR/.complete` — **only** if not a single error occurred.
5. Log a summary, send it via Telegram, exit `0` only on a fully clean run.

Each stack is dumped in its own subshell: a stack that fails ends there, the
remaining stacks still run, and every failure shows up in the summary.

## The marker contract

`STAGING_DIR/.complete` is what the pull side checks **before** it pulls
anything. It is written atomically (temp file + `mv` inside the same directory)
and only after a completely error-free run, so it is never seen half-written and
never vouches for a partial staging directory. Its content:

```
completed_at=2026-07-28T14:03:21+0200
completed_epoch=1785249801
host=vps01
stacks_ok=3
stacks_total=3
dump_bytes=248123456
generator=docker-db-dump
```

The pull side may use the file's mtime or `completed_epoch`; both say the same
thing. **What matters for the pull script:** marker present *and* not older than
a configurable threshold → pull. Otherwise → abort and alarm, pull nothing.

A failed run deliberately leaves an **existing older marker untouched** instead
of deleting it. The pull side then still sees yesterday's timestamp, still has
yesterday's valid dumps, and raises the alarm as soon as its freshness threshold
is exceeded. Deleting the marker would escalate a single failed stack into a
total backup outage.

## Configuration model

Nothing is hard-coded in the script. Configuration is split in two, exactly as
in the reference repository:

### `global.conf` — the whole run

| Variable | Default | Meaning |
|---|---|---|
| `STAGING_DIR` | — (required) | Where the dumps are collected and the backup host pulls from. |
| `STACKS_BASE` | empty | Base directory whose sub-directories are the stacks. A stack without its own `STACK_DIR` is expected in `$STACKS_BASE/<name>`. |
| `STACKS_DIR` | `stacks/` next to the script | Where the per-stack configurations live. |
| `MARKER_NAME` | `.complete` | Name of the marker inside `STAGING_DIR` — the contract with the pull side. |
| `DUMP_RETENTION_DAYS` | `7` | Default retention of the dumps in staging (per stack overridable). |
| `LOG_RETENTION_DAYS` | `64` | Log retention; the script rotates its own logs, no logrotate needed. |
| `STAGING_MODE` | `0750` | Mode of the staging directories. |
| `STAGING_GROUP` | empty | Group that may read the dumps — the pull user's group. |
| `DUMP_UMASK` | `0027` | umask for the dumps (→ files `0640`). |
| `DOCKER_STOP_TIMEOUT` | `20` | Timeout for `docker compose stop`; only relevant with `STOP_SERVICES`. |
| `EXTRA_PATH` | empty | Directories prepended to `PATH` (cron has a minimal one). |
| `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` | `xxx` | Notification; `xxx`/empty disables it. |

### `stacks/<name>.conf` — one file per database

Adding a database means **adding a file**, never editing the script. The file
name (without `.conf`) is the stack name: the label in the log, the
sub-directory under `STAGING_DIR`, and the directory name under `STACKS_BASE`.

| Variable | Default | Meaning |
|---|---|---|
| `ENGINE` | — (required) | `postgres`, `mariadb`, `sqlite` or `custom`. |
| `STACK_DIR` | `$STACKS_BASE/<name>` | Directory holding the `docker-compose.yml`. |
| `ENABLED` | `true` | `false` skips the stack without deleting its configuration. |
| `RETENTION_DAYS` | `DUMP_RETENTION_DAYS` | Retention for this stack's dumps. |
| `DB_SERVICE` / `DB_CONTAINER` | empty | Pin the database container if autodetection is ambiguous. |
| `DB_USER` / `DB_NAME` / `DB_PASSWORD` | empty | Credential overrides; normally resolved inside the container. |
| `SQLITE_FILES` | empty | `ENGINE=sqlite`: one entry per database file. |
| `DUMP_SCRIPT` | `$STACK_DIR/db-dump.sh` | `ENGINE=custom`: the stack's own dump script. |
| `STOP_SERVICES` | empty | Compose services to stop for the duration of the dump — rarely needed, see [Quiescing the writers](#quiescing-the-writers-stop_services). |

Each file is sourced on its own with all of these reset beforehand, so values
never leak between stacks. `$STACK_DIR` is already set while the file is read,
so `SQLITE_FILES=( "$STACK_DIR/data/db.sqlite" )` works.

## The engines

**`postgres` / `mariadb`** — the dump runs via `docker exec` inside the
container and is streamed to the host, so no bind mount and no
`docker-compose.yml` change is needed. The container is auto-detected within the
stack's compose project by image name, exposed port (5432/3306) or the engine's
environment variables — so derivatives such as pgvector, pgvecto-rs, postgis,
timescale or percona are found even though their image name gives nothing away.
Credentials are resolved **inside** the container from the usual variables and
their `_FILE` (docker secret) variants. A stack with several databases reports
the ambiguity; pin one with `DB_SERVICE`.

A plain SQL dump is consistent on its own (`--single-transaction --quick` for
MariaDB), which is why — unlike the reference repository — **nothing is stopped
by default**.

**`sqlite`** — SQLite has no server: the database is a file on the host, so the
dump runs entirely outside the container with the host's `sqlite3`. The online
`.backup` produces a consistent copy even while the application has the database
open.

**`custom`** — hands over to the stack's own `db-dump.sh` (see
`examples/db-dump.custom.sh`). The escape hatch for several databases of
different types in one stack, for engines without a helper (MongoDB, InfluxDB,
…), or for an application-specific export before the SQL dump. It is run with
`STACK_NAME`, `STACK_DIR`, `DUMP_DIR`, `RETENTION_DAYS` and `DB_DUMP_LIB` in its
environment, so it writes into the staging directory without knowing about it.

### Quiescing the writers (`STOP_SERVICES`)

Stops the listed compose services for the duration of the dump, so nothing
writes to the database while it is read. Empty by default — and for most stacks
that is the right value.

**It does not give you a matching file+database state.** This script produces
the DB dump; the stack's *files* are pulled by the backup host later, in a
separate step, with the application long since running again. Anything that
drifts apart between dump and pull drifts apart either way. Real file/database
consistency requires capturing the files atomically **inside the same stopped
window** — an LVM/ZFS/btrfs snapshot or a copy into the staging directory. That
is a separate job and deliberately not part of this script.

Set it only where the dump method itself has no online consistency:

| Case | Why stopping helps |
|---|---|
| MyISAM/Aria tables | `--single-transaction` covers InnoDB only, and the dump uses `--all-databases`, so MariaDB's own system tables are always included. Rarely a problem, but the one case where stopping changes anything for MariaDB. |
| SQLite behind a busy writer | `.backup` is consistent online, but a writer that never pauses makes it restart and it can end in `SQLITE_BUSY`. |
| `ENGINE="custom"` without an online dump | Redis, LevelDB/BoltDB and other embedded stores copied as files — here stopping is the only correct option. |

Not needed for plain postgres or InnoDB-only MariaDB/MySQL: there it buys
nothing and costs downtime.

For `postgres`/`mariadb` do **not** list the database service itself; it has to
be running to be dumped. The services are started again on every exit path,
including a failed dump. A stack whose services could not be restarted counts as
failed and suppresses the completion marker, so a container left down never goes
unnoticed.

## Setup

1. **Place the files**, e.g. in `/opt/docker-db-dump`, and make the script
   executable:
   ```bash
   chmod +x docker-db-dump.sh
   ```

2. **Create the global configuration:**
   ```bash
   cp global.conf.example global.conf
   $EDITOR global.conf          # STAGING_DIR, STACKS_BASE, Telegram, …
   chmod 600 global.conf        # contains the Telegram token
   ```

3. **One configuration per database:**
   ```bash
   cp stacks/stacks.conf.example stacks/nextcloud.conf
   $EDITOR stacks/nextcloud.conf
   chmod 600 stacks/*.conf       # may contain DB_PASSWORD
   ```
   For most stacks two lines are enough:
   ```bash
   ENGINE="postgres"
   ```

4. **Prepare the pull access** — the backup host needs to read the dumps, and
   nothing more. A SQL dump holds the entire database, so it must not become
   world-readable:
   ```bash
   groupadd dbpull
   useradd -r -g dbpull -s /usr/sbin/nologin dbpull    # the pull user
   ```
   then set `STAGING_GROUP="dbpull"` in `global.conf`. The script creates the
   staging directories `0750` and setgid and writes the dumps `0640`, so the
   group can read them and nobody else can.

   On the backup side, give that user a dedicated SSH key restricted to
   `STAGING_DIR` (forced command, no interactive login). Everything about the
   pull itself belongs to the pull script, not here.

5. **Test the run** before putting it in cron:
   ```bash
   ./docker-db-dump.sh --list             # what is configured?
   ./docker-db-dump.sh --stack nextcloud  # dump one stack (writes no marker)
   ./docker-db-dump.sh                    # the full run
   ```

6. **Schedule it**, early enough that the dumps are finished before the backup
   host pulls:
   ```cron
   30 2 * * * /opt/docker-db-dump/docker-db-dump.sh >/dev/null 2>&1
   ```
   The script logs to its own file and notifies via Telegram, so cron mail is
   not needed. It needs access to the docker socket — run it as root.

## Manual runs

```
Usage: docker-db-dump.sh [options]

  -s, --stack NAME   Dump only this stack (repeatable). A partial run NEVER
                     writes the completion marker.
  -l, --list         List the configured stacks and exit.
  -h, --help         Show this help and exit.
```

`--stack` is for testing a new `stacks/<name>.conf`, not for scheduled runs: a
partial run leaves the marker alone, because it says nothing about the stacks it
did not touch.

## Logging and notifications

One log file per run, `logs/db-dump-<timestamp>.log`, written to the terminal at
the same time and world-readable (paths and sizes, never secrets). Old logs are
deleted after `LOG_RETENTION_DAYS` — no logrotate configuration on the host.

Telegram gets a summary at the end of every run with a per-stack status; on
failure the last 50 log lines are attached. An unexpected abort raises its own
alarm through the EXIT trap.

**Exit code `0` only on a completely error-free run** — that is what cron or a
monitoring wrapper evaluates. Any error (a failed dump, an unusable stack
configuration, a service that could not be restarted) means exit `1` *and* no
completion marker.

## Relationship to restic-docker-backup

The dump logic comes from
[restic-docker-backup](https://github.com/sisyphosloughs/restic-docker-backup)
and is deliberately **not** reinvented: `lib/db-dump-lib.sh` is vendored from
there, including its container autodetection, credential resolution and
retention. Keep it in sync with upstream; the two local modifications are listed
in its header (`DUMP_DIR` overridable, and the dump's real path in the log
message).

What differs from the reference repository, and why:

- **Pull instead of push.** This script does not know any backup target. restic
  runs on the backup host, against files it fetched itself.
- **Central staging.** Dumps go to `STAGING_DIR/<stack>/` instead of
  `<stack>/db-dumps/`, so the backup host pulls exactly one tree.
- **No stop/start by default.** SQL dumps are already consistent. Upstream stops
  stacks around the *backup*, which also covers their files; here the files are
  pulled separately later, so a stop around the dump could not achieve that
  anyway. `STOP_SERVICES` remains for the narrow set of cases where the dump
  method itself has no online consistency (see above).
- **Configuration instead of a wrapper per stack.** A stack is one
  `stacks/<name>.conf`; the wrapper-script pattern from upstream's `examples/`
  is still available through `ENGINE="custom"`.

## Troubleshooting

**"no <engine> container auto-detected"** — the stack is down, or its database
container carries none of the detection signals. Pin it with `DB_SERVICE=` (the
compose *service* name, not `container_name:`) or `DB_CONTAINER=`.

**"multiple <engine> containers matched"** — several databases in that stack.
Disambiguate with `DB_SERVICE=`.

**"dump produced an empty file"** — the dump command ran but wrote nothing,
almost always wrong credentials. The empty file is deleted rather than backed
up. Set `DB_USER`/`DB_PASSWORD`/`DB_NAME` explicitly.

**"docker not found" under cron, but it works in the shell** — cron's minimal
`PATH`. Set `EXTRA_PATH` in `global.conf`.

**The pull side reports a stale marker** — look at the last log in `logs/`: the
run failed somewhere, and the marker was withheld on purpose. Fix the stack, run
the script once manually, and the marker is current again.
