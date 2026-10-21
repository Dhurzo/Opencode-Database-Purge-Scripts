# OpenCode Purge Plugin

An OpenCode plugin that exposes the `/purge` command and the `purge_history`
tool, integrating [opencode-cleanup.sh](opencode-cleanup.sh) directly into the
TUI.

---

## Table of contents

1. [Architecture](#architecture)
2. [Installation](#installation)
3. [Usage](#usage)
4. [How it works internally](#how-it-works-internally)
5. [Components](#components)
6. [Limitations and notes](#limitations-and-notes)
7. [Alternatives on GitHub](#alternatives-on-github)

---

## Architecture

```
                     OpenCode (TUI, LLM)
                           │
              /purge 3  ───┘  (markdown command or natural request)
                           │
              LLM → tool.purge_history  (plugin index.js)
                           │
            spawn(bash, [launcher, --months 3],
                   { detached:true, stdio:"ignore" })
                           │  ── .unref() ──> watcher does NOT block OpenCode
                           ▼
                ┌──────────────────────────────┐
                │ opencode-purge-launcher.sh   │  ← new session (detached)
                │                              │
                │ 0. flock (single instance)   │
                │ 1. pgrep -x opencode == 0 ?  │  ← wait for close
                │ 2. opencode-cleanup.sh --dry-run
                │ 3. opencode-cleanup.sh --months N --yes
                │ 4. (opt) term-GUI → opencode │  ← only if OPENCODE_PURGE_RELAUNCH=1
                └──────────────────────────────┘
                            │
                            ▼
                  OpenCode reopened (manual or GUI)
```

### Why a *detached* watcher?

1. **The LLM runs inside `opencode`.** It cannot cleanly kill its own process:
   if `spawn` tried `kill(getppid())`, it would destroy both the tool and its
   own session.

2. **The DB needs exclusive access.** `opencode-cleanup.sh` already checks with
   `pgrep -x opencode` and refuses to run while OpenCode is active. The watcher
   **waits** for it to close before touching the DB.

3. **`detached: true` guarantees survival.** On POSIX, Node creates a new
   session (equivalent to `setsid`) and a new process group; with
   `stdio:"ignore"` the watcher inherits no FDs and receives no signals from
   the terminal or parent process. `.unref()` ensures OpenCode's *event loop*
   does not wait for it. The `setsid` binary is not required.

---

## Installation

### 1. Copy the plugin

```bash
PLUGIN_DIR="$HOME/.config/opencode/plugins/opencode-purge"
COMMANDS_DIR="$HOME/.config/opencode/commands"
mkdir -p "$PLUGIN_DIR" "$COMMANDS_DIR"
cp ~/Repos/cleanOpencodeDB/plugin/index.js "$PLUGIN_DIR/"
cp ~/Repos/cleanOpencodeDB/plugin/package.json "$PLUGIN_DIR/"
cp ~/Repos/cleanOpencodeDB/commands/purge.md "$COMMANDS_DIR/"
```

`index.js` and `package.json` live in this repo under [`plugin/`](plugin/);
`commands/purge.md` lives under [`commands/`](commands/). Symlinks also work.

### 2. Register in `opencode.json`

You only need to add the plugin to `plugin[]`. The `/purge` command is defined
in `commands/purge.md` (a single source of truth — do not duplicate it inline
in `opencode.json`):

```jsonc
{
  // "command": {} — not needed; the command lives in commands/purge.md
  "plugin": [
    /* ...other plugins... */
    "opencode-purge"   /* ← bare name: ~/.config/opencode/plugins/opencode-purge/ */
  ]
}
```

A complete example is available in
[`opencode.json.example`](opencode.json.example).

> **Local plugins** are resolved as bare names →
> `~/.config/opencode/plugins/<name>/`.

### 3. Symlink the launcher

```bash
ln -sf ~/Repos/cleanOpencodeDB/opencode-purge-launcher.sh \
       ~/.local/bin/opencode-purge-launcher.sh
```

> The `@opencode-ai/plugin` dependency **does not need a local install**: Node
> resolves the `import` by walking up the tree to
> `~/.config/opencode/node_modules/@opencode-ai/plugin/`.

### 4. Reload

Restart OpenCode (or reload the config). Verify with `/help` or by typing
`/purge`.

---

## Usage

```bash
# Slash command (takes $ARGUMENTS as months):
/purge 1          # keep only the last month
/purge 3          # keep 3 months
/purge 12         # keep 1 year

# Or ask the agent naturally:
"purge conversations older than 2 months"
```

Retention is configurable: `/purge N` accepts integers from **1 to 60 months**
(default `2`). `0`, negative values, non-integers, and `>60` are rejected
without launching anything.

### Script-level options (not passed through the plugin)

`/purge` only passes `--months`. Additional
[`opencode-cleanup.sh`](opencode-cleanup.sh) options are used by running it
directly (with OpenCode closed):

```bash
opencode-cleanup.sh --months 3 --by-updated --strip-reasoning \
  --strip-tool-output --events-older-than 30 --backup --yes
```

- `--by-updated`: retain by last activity instead of creation date.
- `--keep-session ID` / `--keep-project ID`: protect sessions or projects.
- `--strip-reasoning` — empties the hidden reasoning text in parts (reclaims
  space without deleting sessions).
- `--strip-tool-output` — empties tool output.
- `--events-older-than DAYS` — prunes the event log for inactive sessions
  (opt-in; keeps `event_sequence`).
- `--backup` / `--backup-keep N` — consistent snapshot (`.backup`) and
  retention.
- The script checks `quick_check`/`integrity_check` before and after, detects
  processes using the DB with `pgrep`/`fuser`, takes a `flock`, and leaves
  `auto_vacuum=INCREMENTAL` so the DB does not bloat again. `--yes` does not
  skip the in-use DB guard (that is what `--force` is for).

Typical watcher output
(`$XDG_STATE_HOME/opencode-purge/purge.log`, by default
`~/.local/state/opencode-purge/purge.log`):

```
========================================================
[17:50:02] opencode-purge-launcher started (months=3)
[17:50:02] Waiting for OpenCode to close...
[17:53:15] OpenCode closed after 193s. Proceeding with cleanup.

[17:53:15] === DRY-RUN (deletion plan) ===
== opencode conversation cleanup ==
  Cutoff:   2025-06-02 09:59:58
  Sessions to delete (includes descendants): 142
  Orphans in storage: 89 ses_* keys, 412 msg_* keys
  Events to prune (--events-older-than 30): 357737
  Free pages: 4643796 (18139 MB)
--dry-run mode: nothing was changed.

[17:53:20] === CLEANUP (real run) ===
DB updated: 142 sessions deleted...
  ...
  Total freed: 19876 MB

[17:53:45] === REOPEN ===
[17:53:45] Cleanup complete. REOPEN OpenCode whenever you like:
[17:53:45]   • type `opencode` in your terminal, or
[17:53:45]   • (optional) set OPENCODE_PURGE_RELAUNCH=1 to reopen it in a GUI automatically.
```

---

## How it works internally

### Plugin (`index.js`) — v1 API (`@opencode-ai/plugin@1.4.7`)

The plugin exports an async factory that receives `ctx` (PluginInput) and
returns a `Hooks` object with a `tool` key:

```js
import { spawn } from "node:child_process";
import { accessSync, constants } from "node:fs";
import { tool } from "@opencode-ai/plugin";

export default async (ctx) => {
  const home = process.env.HOME || ctx.directory;
  return {
    tool: {
      purge_history: tool({
        description: "...",
        args: { months: tool.schema.number({ default: 2, min: 1 }).describe("...") },
        async execute(args) {
          // ⚠️ opencode's zod does NOT apply min/default at runtime
          // (verified: safeParse(0) passes; safeParse(undefined) fails).
          // The real validation is explicit and lives here:
          const raw = args.months;
          const months = raw === undefined ? 2 : Number(raw);
          if (!Number.isInteger(months) || months < 1 || months > 60) {
            return "❌ invalid months (1..60). No purge was launched.";
          }
          // Does the launcher exist? A spawn failure would only reach
          // opencode's console.error (invisible) while the tool had already
          // replied "purge scheduled", which would be a lie.
          try {
            accessSync(launcher, constants.R_OK);
          } catch {
            return "❌ Cannot find the launcher (create the symlink). Nothing was launched.";
          }
          const child = spawn(
            "bash",                             // no dependency on the setsid binary
            [launcher, "--months", String(months)],
            { stdio: "ignore", detached: true } // new session + own process group
          );
          child.unref();                         // do not block the event loop
          child.on("error", () => {});           // do not propagate spawn failures
          return "🧹 Purge scheduled …";
        },
      }),
    },
  };
};
```

**Key API concepts:**

| Element | Type | Purpose |
|---|---|---|
| `Plugin` | `(input, options?) => Promise<Hooks>` | Plugin factory |
| `PluginInput` | `{ ctx, directory, worktree, $, ... }` | Received in `setup`/factory |
| `tool` | Zod-based helper | Defines tools callable by the LLM |
| `ToolContext` | `{ sessionID, messageID, directory, worktree, abort, ... }` | Received in `execute` |

> **Version note.** In OpenCode V1 (`1.x`) the API is the factory function
> shown above. In V2 (`2.x`) it changes to `Plugin.define({ id, setup })`. This
> plugin uses the V1 API.

### Watcher (`opencode-purge-launcher.sh`)

```bash
spawn("bash", [LAUNCHER, "--months", N], { detached: true, stdio: "ignore" })
```

Phases (`set -uo pipefail`, without `-e` so failures during relaunch do not
abort it):

1. **Parse** `--months` (default 2): validates `^[0-9]+$` and the 1..60 range;
   exits with an error **before** the poll if invalid.
2. **Redirection** — all output goes to the log (`$OPENCODE_PURGE_LOG`, or
   `$XDG_STATE_HOME/opencode-purge/purge.log`); it is rotated when it exceeds
   `OPENCODE_PURGE_LOG_MAX` (5 MiB by default).
3. **Single-instance lock** — `flock -n` on
   `$XDG_RUNTIME_DIR/opencode-purge/launcher.lock` (fallback
   `/tmp/opencode-purge-$UID/launcher.lock`); if a watcher is already running,
   the new one exits immediately and records that in the log.
4. **Close poll** — `while pgrep -x opencode; do sleep 2; done`
   (`OPENCODE_PURGE_TIMEOUT`, 300 s by default).
5. **Dry run** — `bash "$CLEANUP" --months "$MONTHS" --dry-run` (log info only).
6. **Cleanup** — `bash "$CLEANUP" --months "$MONTHS" --yes` (`--yes` skips the
   interactive confirmation; the DB is unlocked because OpenCode has closed).
   If it fails, the log records it, `notify-send` is attempted, and the launcher
   exits with an error code instead of announcing "cleanup complete".
7. **Reopen** — by default it only tells the user to reopen OpenCode. If
   `OPENCODE_PURGE_RELAUNCH=1`, it launches the emulator with the correct
   syntax for each one (`gnome-terminal -- opencode`,
   `wezterm start -- opencode`, `kitty opencode`, `-e opencode` for
   xterm/konsole/alacritty/x-terminal-emulator).

### Markdown command (`commands/purge.md`)

Markdown commands are sent to the LLM as a *prompt* (with `$ARGUMENTS`
substituted). The LLM interprets it and decides to call the `purge_history`
tool:

```markdown
---
description: Purge old OpenCode conversations & compact DB (closes & reopens OpenCode)
---
The user wants to purge OpenCode conversations older than $ARGUMENTS months.
Use the purge_history tool with months set to $ARGUMENTS. ...
```

---

## Components

| Component | Type | Responsibility |
|---|---|---|
| `opencode-cleanup.sh` | Bash | Deletion + compaction logic (the real engine). Supports retention, keep-lists, stripping, events, backup, and verification. |
| `opencode-purge-launcher.sh` | Bash | close→clean→reopen orchestration (watcher), with timeout, lock, log rotation, and notifications. |
| `plugin/index.js` | TypeScript/JS (plugin) | Registers the `purge_history` tool; launches the watcher. |
| `commands/purge.md` | Markdown | `/purge` entry point for the LLM. |
| `opencode.json.example` | JSON | Example plugin registration (the command lives in `commands/purge.md`). |

---

## Limitations and notes

1. **Closing is manual.** The watcher waits for the user to close OpenCode. It
   cannot do it for you (the LLM died with the process). The tool message says:
   *"type `/exit`, press Ctrl+C, or close the window"*.

2. **Wait timeout: 300 s.** If you do not close OpenCode within that time, the
   watcher aborts and records it. Adjust it with `OPENCODE_PURGE_TIMEOUT`
   (seconds).

3. **Reopening is NOT automatic by default.** A detached process has no
   controlling TTY, and the OpenCode TUI needs one. Reopen OpenCode manually,
   or set `OPENCODE_PURGE_RELAUNCH=1` to reopen it in a GUI terminal emulator
   (best-effort; requires `DISPLAY`/`WAYLAND_DISPLAY` and an installed
   emulator: `x-terminal-emulator`, `xterm`, `gnome-terminal`, `konsole`,
   `alacritty`, `kitty`, or `wezterm`; or override with
   `OPENCODE_PURGE_TERM`).

4. **One watcher at a time (`flock`).** The launcher takes a non-blocking lock
   (`$XDG_RUNTIME_DIR/opencode-purge/launcher.lock`, adjustable with
   `OPENCODE_PURGE_LOCK`): if a purge is already running, the second watcher
   exits immediately instead of piling up. The cleanup also uses its own lock
   (`OPENCODE_CLEANUP_LOCK`) to serialize manual runs.

5. **A single command.** `/purge` is defined in `commands/purge.md`. Do not
   duplicate it as an inline `command.purge` in `opencode.json` (redundant
   registration).

6. **No interactive dry run.** The watcher runs cleanup with `--yes` (no
   confirmation) because OpenCode is already closed and there is no TTY. If you
   want to review before deleting, run `opencode-cleanup.sh --dry-run` manually
   after closing OpenCode.

7. **`event`/`event_sequence` relationship.** The DB uses `aggregate_id` as a
   shared key between `session.id` and `event_sequence.aggregate_id`. The FK
   `event.aggregate_id → event_sequence(aggregate_id) ON DELETE CASCADE` (with
   `PRAGMA foreign_keys=ON`) deletes events in a chain when a session is
   deleted. To prune only old events without deleting the session, use
   `--events-older-than DAYS`, which deletes rows from `event` and **keeps**
   `event_sequence`. It is opt-in: consider first whether you use sync/replay
   between clients.

---

## Alternatives on GitHub

| Project | Type | Key difference |
|---|---|---|
| [opencode-sweeper](https://github.com/jeffusion/opencode-sweeper) | Plugin | Deletes sessions via the SDK while running; no close, no VACUUM (the file does not shrink). |
| [ocgc](https://github.com/whtsky/ocgc) | CLI | GC by age/size, orphans, snapshots, `strip-reasoning`; runs outside the TUI. |
| [ocdbc](https://github.com/chncaesar/opencode-db-clean) | Python CLI | Safe VACUUM (backup + `integrity_check` + `auto_vacuum`); no deletion by age. |
| [opencode-helper](https://github.com/v587d/opencode-helper) | Python CLI | Deletion + VACUUM with a protected-session list; Windows-focused. |

This plugin covers the full cycle from the TUI: **close → delete (sessions +
orphans) → VACUUM → reopen**, something none of the alternatives do (opencode
upstream has no cleanup either: issue
[#4980](https://github.com/sst/opencode/issues/4980)).
