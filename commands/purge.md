---
description: Purge OpenCode conversations older than N months and compact the DB
---

The user wants to purge OpenCode conversations older than `$ARGUMENTS` months.

Use the `purge_history` tool with `months` set to `$ARGUMENTS`. Rules:

- If `$ARGUMENTS` is empty, use `2`.
- It must be an integer between 1 and 60. If it is not, do not call the tool;
  explain the valid range and ask for a correct value.
- After calling the tool, relay its instructions to the user: they must close
  OpenCode (`/exit`, Ctrl+C, or close the window) for the detached watcher to
  clean the database. The watcher waits up to 300 seconds by default
  (`OPENCODE_PURGE_TIMEOUT`).
- Do not run `opencode-cleanup.sh` yourself from inside OpenCode: the database
  must not be in use, and VACUUM needs exclusive access.
