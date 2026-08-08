# Stage Log 2026-08-08 Agent Kernel Phase 7 (AGENTS.md stacking)

- Type: logs
- Attention: records
- Status: final
- Scope: project
- Tags: stage, agents-md, project-instructions

## Summary

Phase 7 of the unified agent kernel plan: project instruction
discovery now stacks AGENTS.md ancestors, plain chat injects them
too, and the context optimizer cannot spin forever. Suite: 491
tests, 491 passing.

## What Landed

- New `lisp/core/chat-project.el` (pi resource-loader design):
  `chat-project-collect-agents-files` walks from the start directory
  up to the filesystem root and returns instruction files root-most
  first, deduplicated; `chat-project-instructions` merges the global
  `~/.chat/AGENTS.md` first, then local files with per-file source
  annotations, capped by `chat-project-instructions-max-chars`
  (32 KiB) with a truncation marker.
- Code mode builds its project-instructions source from the stacked
  collector starting at the focus file directory (falling back to
  the project root). The single root file helper is gone.
- Plain chat injects project instructions into its system prompt
  based on `default-directory`.
- `chat-context-code--optimize` stops when there is nothing left to
  truncate or remove, closing the potential infinite loop; removal
  now reports whether it removed anything.

## Test Changes

- New tests/unit/test-chat-project.el (7 tests: root-first
  collection, merged annotations, global first, cap marker, no files,
  plain chat injection, optimizer termination).
- The code-mode AGENTS.md test now asserts the source annotation
  format instead of the old single-file header.

## Verification

- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
  reports 491 results as expected, 0 unexpected.

## Not Done

- Phase 8: UI rendering (differential streaming render, collapsible
  tool blocks, diff faces, markdown-lite highlighting).
