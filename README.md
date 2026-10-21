# opencode-cleanup

A script to reclaim the space used by [opencode](https://opencode.ai)
conversation history, keeping only the last **N months** (2 by default) and
compacting the SQLite database.

**Location:** `~/Repos/cleanOpencodeDB/opencode-cleanup.sh`
  (symlinked at `~/.local/bin/opencode-cleanup.sh` so it can be run as a command)

---

## Why it exists

opencode history lives in `~/.local/share/opencode/` and consists of two parts:

| Component | Contents |
|---|---|
| `opencode.db` | SQLite database (WAL mode): sessions, messages, parts, events |
| `storage/` | Auxiliary files outside the DB: parts, session diffs, todos |

Common problems this script solves:

1. **Accumulated free pages.** SQLite does not return space to the system when
   rows are deleted: it keeps them on the *freelist*. On a heavily used install
   this can reach tens of GB. A `VACUUM` reclaims it. Real example: a 23 GB file
   with only ~4.7 GB of data (18+ GB free).
2. **Old sessions.** Conversations older than the cutoff remain stored in the
   DB and in `storage/` forever.
3. **`storage/` orphans.** After a reinstall or major opencode upgrade,
   `storage/` can contain files whose IDs (sessions, messages) no longer exist
   in the current DB. They take up space and serve no purpose.

---

## Requirements

- `bash` 4+ (associative arrays)
- `sqlite3` on `PATH`
- GNU `date` (supports `-d ... +%s%3N`), GNU `xargs`, `find`, `flock`
- `pgrep` (procps) and, optionally, `fuser` (psmisc) to detect the DB in use
- Linux (the watcher and locking use `flock`/`pgrep`/`fuser`)

---

## Usage

```bash
# 1. Close opencode (the script checks and refuses to run while it is running)

# Preview: what would be deleted
opencode-cleanup.sh --dry-run

# Run with confirmation
opencode-cleanup.sh

# Run without asking
opencode-cleanup.sh --yes

# Custom retention (e.g. 6 months)
opencode-cleanup.sh --months 6

# Compact the DB only, without deleting anything
opencode-cleanup.sh --vacuum-only

# Empty "reasoning" blocks (reclaims space without touching the history)
opencode-cleanup.sh --strip-reasoning

# Also empty tool output (state.output/metadata)
opencode-cleanup.sh --strip-tool-output

# Prune the event log for sessions inactive for 30 days
opencode-cleanup.sh --events-older-than 30

# Retain by last activity and protect specific sessions/projects
opencode-cleanup.sh --by-updated --keep-session ses_abc --keep-project 0abc...

# With a consistent backup before writing (keeps the last 3)
opencode-cleanup.sh --backup --backup-keep 3

# Everything at once: delete old sessions, strip reasoning/tools, prune
# events, back up, and compact
opencode-cleanup.sh --months 3 --strip-reasoning --strip-tool-output \
  --events-older-than 30 --backup --yes
```

### Options

| Option | Description |
|---|---|
| `--months N` | Retention in months (integer ≥ 1). Sessions older than `now - N months` are deleted (default `2`). |
| `--by-updated` | Use `session.time_updated` (last activity) instead of `time_created` to decide retention. |
| `--keep-session ID` | Do not delete that session (repeatable). If its parent is deleted, it is reparented to `NULL`. |
| `--keep-project ID` | Do not delete any session from that project (repeatable). |
| `--dry-run` | Show the deletion plan (sessions, orphans, reasoning, tools, events, free pages) without changing anything. |
| `--vacuum-only` | Delete NOTHING: only run `wal_checkpoint(TRUNCATE)` + compaction to reclaim free pages. |
| `--strip-reasoning` | Empty the text of reasoning blocks (`part.data` of type `reasoning`), keeping the row. Incompatible with `--vacuum-only`. |
| `--strip-tool-output` | Empty `state.output` and `state.metadata` on `tool` blocks (keeps `state.input` and the row). Incompatible with `--vacuum-only`. |
| `--events-older-than DAYS` | Prune the `event` table for sessions inactive for `DAYS` days. Keeps `event_sequence` (sequences are not reset). Incompatible with `--vacuum-only`. |
| `--backup` | Take a consistent backup (`sqlite3 .backup`, atomic snapshot) in `opencode.db.backup-<date>/` before any writes. |
| `--backup-keep N` | Keep the `N` most recent backups (0 = all; default `3`). |
| `--yes` | Skip the interactive confirmation. **Does not** disable the in-use DB check. |
| `--force` | Ignore the process check for processes using the DB (dangerous; only if you know what you are doing). |
| `--full-check` | Use `PRAGMA integrity_check` instead of `quick_check` (slower). |
| `--skip-space-check` | Skip the free-space check before `VACUUM`/backup. |
| `-h` / `--help` | Show help. |

---

## What it does exactly

### 1. Old sessions in the DB

Deletes sessions from `opencode.db` with `time_created < cutoff` (millisecond
timestamp; with `--by-updated`, `time_updated`). With `PRAGMA
foreign_keys=ON`, the cascade also removes:

- `message`, `part`, `todo`, `session_share`, `session_message`,
  `session_input`, `session_context_epoch` (FK `ON DELETE CASCADE` from
  `session`)
- `event_sequence` is deleted explicitly; `event` follows via its FK
  `aggregate_id → event_sequence(aggregate_id) ON DELETE CASCADE`. The
  `aggregate_id` is the session ID.

If the schema has `session.parent_id`, selection is **recursive**: child
sessions (subagents) are deleted too, even if they are newer, so no orphaned
sessions are left with a missing `parent_id`. `--keep-session` protects a
specific session and, if its parent is deleted, reparents it to `NULL`.
`--keep-project` protects every session in a project.

### 2. Orphans in `storage/`

Compares `storage/` keys against the current DB IDs:

| Directory | Key | Checked against table |
|---|---|---|
| `storage/message/` | `ses_<id>/` | `session` |
| `storage/session_diff/` | `ses_<id>.json` | `session` |
| `storage/todo/` | `ses_<id>.json` | `session` |
| `storage/agent-usage-reminder/` | `ses_<id>.json` | `session` |
| `storage/directory-readme/` | `ses_<id>.json` | `session` |
| `storage/rules-injector/` | `ses_<id>.json` | `session` |
| `storage/part/` | `msg_<id>/` | `message` |
| `storage/project/` | `<project hash>.json` | `project` |
| `storage/session/<project>/` | per-project dir + `ses_<id>.json` | `project` + `session` |
| `storage/plugin/<plugin>/` | `ses_<id>.json` | `session` |

Anything that does not exist in the DB is deleted **in the same run**: files
that were already orphaned, files belonging to sessions deleted in step 1, and
the `storage/part/` directories of their messages (deleted by cascade).
`storage/session/` directories whose project no longer exists in the DB are
removed entirely; directories for live projects only lose stale `ses_*.json`
files.

> [!NOTE]
> DB IDs already include the prefix (`ses_*`, `msg_*`), just like `storage/`
> keys: they are compared and deleted as-is. (An older version of the script
> prepended the prefix again — `ses_ses_x` — which is why it deleted nothing
> from storage with the current opencode ID format.)

### 3. Compaction

```sql
PRAGMA wal_checkpoint(TRUNCATE);   -- empty the WAL
PRAGMA auto_vacuum=INCREMENTAL;    -- enable the mode that prevents re-bloat
VACUUM;                            -- rebuild the file without free pages
```

After the first run, the DB is left in `auto_vacuum=INCREMENTAL` mode: later
cleanups use `PRAGMA incremental_vacuum`, which reclaims free pages without
rewriting the whole file. This way the DB **does not bloat again** between
cleanups.

### 4. Reasoning blocks (optional, `--strip-reasoning`)

Each agent turn can leave a JSON block of type `reasoning` in `part.data`
containing the text the model "thought" before responding. That text is not
shown in the conversation. `--strip-reasoning` empties it (`"text": ""`),
keeping the row and the session structure:

```sql
UPDATE part
   SET data = json_set(data, '$.text', '')
 WHERE json_extract(data, '$.type') = 'reasoning';
```

On a typical DB this can be tens of MB, without deleting anything visible.
`part.data` values that are not valid JSON are ignored and do not abort the
cleanup.

### 5. Tool output (optional, `--strip-tool-output`)

`tool` blocks store command, tool, and file-read output in
`part.data.state.output`, plus associated metadata in `state.metadata`.
`--strip-tool-output` empties them while keeping the call (`state.input`), the
row, and the session structure:

```sql
UPDATE part
   SET data = json_set(data, '$.state.output', '',
                            '$.state.metadata', json('{}'))
 WHERE json_valid(data)
   AND json_extract(data, '$.type') = 'tool'
   AND json_type(data, '$.state') = 'object';
```

This is usually the largest source of space after the event log.

### 6. Event log (optional, `--events-older-than DAYS`)

The `event` table is an event-sourcing log that duplicates message and part
changes; on active installs it can take up most of the file.
`--events-older-than DAYS` deletes events for sessions inactive for `DAYS`
days:

```sql
DELETE FROM event
 WHERE aggregate_id IN (
   SELECT id FROM session
    WHERE COALESCE(time_updated, time_created) < cutoff
 );
```

`event_sequence` is **not** deleted: sequence numbers are preserved so they are
never reused. Before using this, note that opencode uses this log for
sync/replay between clients; if you use multiple instances or sync, verify that
your version does not depend on old events. It is opt-in, and you should
combine it with `--backup`.

---

## Safety

- **DB lock:** aborts if `opencode` is running **or** if any process has the
  file (or its `-wal`) open (`pgrep -x opencode` + `fuser -s`). VACUUM needs
  exclusive access; `fuser` closes the TOCTOU race between the check and the
  write. `--yes` **does not** skip this guard; only `--force` does,
  explicitly.
- **Single-instance lock:** `opencode-cleanup.sh` takes a `flock`
  (`$XDG_RUNTIME_DIR/opencode-purge/cleanup.lock`) so two manual cleanups
  cannot compete. The launcher uses a different lock.
- **Integrity:** `PRAGMA quick_check` before and after (or `integrity_check`
  with `--full-check`). If it fails before starting, nothing is modified.
- **Free space:** before writing, checks that there is room for the `VACUUM`
  (and for the backup, if requested). `--skip-space-check` skips this.
- **Backup:** with `--backup`, a consistent snapshot (`sqlite3 .backup`,
  atomic) is taken before any writes; `--backup-keep` limits how many backups
  are kept.
- **Confirmation:** asks `y/N` before deleting by default.
- **`--dry-run`:** performs no writes and works while opencode is running
  (read-only); useful for auditing beforehand.
- **VACUUM only:** `--vacuum-only` reclaims space with no risk of data loss.
- **`--strip-reasoning` / `--strip-tool-output`:** do not delete rows or
  sessions, only regenerable content (reasoning and tool output).
- `storage/` deletion is additive: it only touches keys the DB no longer
  references.
- Locks/logs live in user directories (`$XDG_RUNTIME_DIR`, `$XDG_STATE_HOME`)
  with `700/600` permissions; if `XDG_RUNTIME_DIR` is unset, the fallback is
  `/tmp/opencode-purge-$UID` (also `700`).

> [!WARNING]
> Deleting sessions, `--strip-reasoning`, `--strip-tool-output`, and
> `--events-older-than` are irreversible. Although the tool checks integrity,
> make a manual backup (`cp -a ~/.local/share/opencode/ ~/opencode-backup/`)
> before the first run if you are unsure, or use `--backup`. To restore:
> `sqlite3 "$BAK/opencode.db" ".backup '$HOME/.local/share/opencode/opencode.db'"`.

---

## Example output

```
== opencode conversation cleanup ==
  DB:         /home/<user>/.local/share/opencode/opencode.db
  Cutoff:     2026-06-02 09:59:58  (sessions before this date; column: time_created)
  DB now:          22702 MB
  Storage now:     1745 MB

Sessions to delete from the DB (created more than 2 months ago; includes descendants): 0
Messages from those sessions (cascade; their storage/ parts are deleted too): 0
Orphans in storage (no longer in the DB): 3127 ses_* keys, 20438 msg_* keys, 0 projects
Events to prune (--events-older-than 30): 357737 (2500 MB)
Free pages in the DB: 4643796 (18139 MB)

  Integrity: OK (quick_check)
  Free space: 90000 MB (needed ~22702 MB)
  Backup created: .../opencode.db.backup-20261021-.../opencode.db
  DB updated: 0 sessions deleted (messages, parts, events by cascade).
  Events pruned: 357737 (event_sequence preserved).
  Compaction: incremental_vacuum (auto_vacuum=INCREMENTAL active).

== Result ==
  Free pages:  4643796 -> 0
  DB:          22702 MB -> 4563 MB
  Storage:     1745 MB -> 8 MB
  Total freed: 19876 MB
```

---

## Environment variables

| Variable | Description |
|---|---|
| `OPENCODE_DIR` | Path to `~/.local/share/opencode` (default `$HOME/.local/share/opencode`). Useful for testing against copies. |
| `OPENCODE_CLEANUP_LOCK` | Path to the cleanup single-instance lock (default: `$XDG_RUNTIME_DIR/opencode-purge/cleanup.lock`). |
| `XDG_RUNTIME_DIR` / `XDG_STATE_HOME` | Standard directories for locks and logs (the launcher uses `$XDG_STATE_HOME/opencode-purge/purge.log`). |

---

## Maintenance

- It can be scheduled (e.g. monthly `cron`) with `--vacuum-only --yes` to keep
  the DB compact without losing history. `--yes` no longer disables the in-use
  DB guard: if opencode is open, the run aborts without touching anything.
- To control event-log growth, test on a copy first:
  `opencode-cleanup.sh --events-older-than 30 --months 12 --backup --yes`.
- A full cleanup (`--months 2`) only deletes conversations; running it with
  opencode closed is recommended.
- Tests: `bash test/run-tests.sh` runs an end-to-end suite (157 assertions)
  against a hermetic fixture in `/tmp` — it does not touch your real DB.
- CI: `.github/workflows/ci.yml` runs shellcheck, syntax checks, and the suite
  on Ubuntu.

---

## OpenCode plugin (`/purge`)

This project also includes an **OpenCode plugin** that exposes the `/purge`
command and the `purge_history` tool, integrating cleanup directly into the
OpenCode TUI.

### What it does

| File | Location | Role |
|---|---|---|
| `opencode-purge-launcher.sh` | repo root (`~/Repos/cleanOpencodeDB/`) | *Detached* watcher: waits for OpenCode to close, runs `opencode-cleanup.sh`, and tells you to reopen OpenCode. |
| `plugin/index.js` | repo (`plugin/`) → `~/.config/opencode/plugins/opencode-purge/` | Plugin (v1 API) that registers the `purge_history` tool. |
| `commands/purge.md` | repo (`commands/`) → `~/.config/opencode/commands/` | Markdown `/purge` command (the LLM's entry point). |
| `opencode.json.example` | repo | Minimal example of plugin registration in `opencode.json`. |

> **Architecture.** The OpenCode LLM runs *inside* the `opencode` process. It
> cannot kill its own process, and the DB needs exclusive access for `VACUUM`.
> That is why `purge_history` does not delete anything directly: **it launches a
> *detached* process (`detached:true` → `setsid` on POSIX + `stdio:"ignore"` +
> `.unref()`) that:**
> 1. *Waits* (`pgrep -x opencode == 0`) for you to close OpenCode (300 s by
>    default; `OPENCODE_PURGE_TIMEOUT`).
> 2. Runs `opencode-cleanup.sh --dry-run` (plan goes to the log).
> 3. Runs `opencode-cleanup.sh --months N --yes` (deletion + VACUUM).
> 4. **Does not blindly reopen the TUI** — a detached process has no
>    controlling TTY, and the OpenCode TUI needs one. By default it tells you to
>    reopen it manually. If you set `OPENCODE_PURGE_RELAUNCH=1`, it tries to
>    reopen it in a GUI terminal emulator (best-effort; requires a graphical
>    session).
>
> The watcher survives the death of the OpenCode process and takes a `flock`
> (`$XDG_RUNTIME_DIR/opencode-purge/launcher.lock`): if a purge is already
> running, a second watcher exits immediately without touching anything. The
> log is at `$XDG_STATE_HOME/opencode-purge/purge.log` (or
> `~/.local/state/...`).

### Installation

The plugin is installed outside this repo (in your OpenCode config). If you use
this repo as the single source, symlink the launcher just like the cleanup
script:

```bash
# 1. Symlink the launcher (global command)
ln -sf ~/Repos/cleanOpencodeDB/opencode-purge-launcher.sh ~/.local/bin/opencode-purge-launcher.sh

# 2. Plugin + command in ~/.config/opencode/ — see README-PLUGIN
#    (plugin/index.js, commands/purge.md, opencode.json.example)
```

### Usage

```bash
# Inside the OpenCode TUI:
/purge 1                                   # keep only the last month
/purge 3                                   # keep 3 months
/purge 12                                  # keep 1 year
# No argument → default retention (2 months)

# Or ask the agent naturally:
"purge conversations older than 2 months"

# The watcher writes everything to:
tail -f "${XDG_STATE_HOME:-$HOME/.local/state}/opencode-purge/purge.log"
```

Retention is configurable: `/purge N` accepts integers from **1 to 60 months**.
Out-of-range values (including `0`) are rejected without launching anything, so
you cannot accidentally delete your entire history.

Flow:

1. OpenCode shows: *"Purge scheduled (N months). Close OpenCode (Ctrl+C or /exit)."*
2. The watcher detects the close → cleans → records it in the log.
3. You reopen OpenCode manually (or, if you enabled
   `OPENCODE_PURGE_RELAUNCH=1`, it opens automatically in a GUI terminal
   window).

---

## Similar projects on GitHub

| Project | Type | Key difference from this one |
|---|---|---|
| [jeffusion/opencode-sweeper](https://github.com/jeffusion/opencode-sweeper) | Plugin | Deletes expired sessions via the SDK while OpenCode runs; **does not close the app or VACUUM** (the file does not shrink). |
| [whtsky/ocgc](https://github.com/whtsky/ocgc) | CLI (garbage collector) | Purges by age/size, orphans, snapshots, `strip-reasoning`; runs outside the TUI. |
| [chncaesar/opencode-db-clean](https://github.com/chncaesar/opencode-db-clean) | Python CLI (`ocdbc`) | Safe VACUUM sequence (backup + `integrity_check` + `auto_vacuum`); does not delete sessions by age. |
| [v587d/opencode-helper](https://github.com/v587d/opencode-helper) | Python CLI (Windows) | Session deletion + VACUUM with a protected-session list. |

**None of them completes the full cycle from inside the TUI**: close OpenCode →
delete old sessions + orphans → `VACUUM` (the file really shrinks) → reopen.
That is the gap this project fills.

> opencode upstream has no built-in cleanup (issue
> [#4980](https://github.com/sst/opencode/issues/4980)); DB bloat is a known
> problem ([#16101](https://github.com/sst/opencode/issues/16101),
> [#31526](https://github.com/sst/opencode/issues/31526)).
