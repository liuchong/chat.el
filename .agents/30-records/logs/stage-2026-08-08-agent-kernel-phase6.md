# Stage Log 2026-08-08 Agent Kernel Phase 6 (session JSONL and memory)

- Type: logs
- Attention: records
- Status: final
- Scope: project
- Tags: stage, session, jsonl, memory

## Summary

Phase 6 of the unified agent kernel plan: sessions persist as
append-only JSONL with transparent legacy migration, and long term
memory lands as a user curated file. Suite: 484 tests, 484 passing.

## What Landed

- Session files are now `~/.chat/sessions/<id>.jsonl`: a header
  entry, a state entry, and one entry per message
  (`chat-session-format-version` 1).
- `chat-session-add-message` appends two lines (message + state)
  instead of rewriting the whole file, removing the O(file size)
  write per message.
- Structural operations (create, clear, truncate, replace, rename,
  auto-approve) still write the full file, atomically via temp +
  rename.
- `chat-session-load` replays JSONL, skipping corrupt lines; legacy
  `.json` files load once and migrate transparently (the JSONL file
  is written and the legacy file removed). `chat-session-list`
  prefers JSONL when both exist, and delete/exists cover both names.
- New `lisp/core/chat-memory.el`: `~/.chat/memory.md` is injected
  into every system prompt through
  `chat-tool-caller-build-system-prompt` (both chat and code mode),
  capped by `chat-memory-max-chars` (8000) with a truncation marker.
  `M-x chat-edit-memory` opens the file. Sessions stay isolated;
  memory is explicitly user curated.

## Test Changes

- 4 JSONL tests: append-only growth, legacy migration, corrupt line
  tolerance, list dedupe.
- 4 memory tests: missing file, injection into the prompt,
  truncation, empty file.
- One legacy assertion updated to the `.jsonl` file name.

## Verification

- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
  reports 484 results as expected, 0 unexpected.

## Not Done

- Phases 7-8: AGENTS.md ancestor stacking, UI rendering.
- kimi-cli's context/wire file separation is not ported; the JSONL
  message entries cover both roles for now.
