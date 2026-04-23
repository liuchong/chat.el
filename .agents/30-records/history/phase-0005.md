# Phase 0005

- Type: progress
- Attention: records
- Status: completed
- Scope: request-panel
- Tags: phase, request-panel, diagnostics, ui

## Goal

Move request progress visibility out of the chat transcript and into a dedicated structured panel shared by chat mode and code mode.

## Completed

- Added `lisp/ui/chat-request-panel.el` as the shared request panel module
- Added `C-c C-p` toggles in normal chat and code mode
- Stopped rendering tool step timelines inline in assistant transcript output
- Routed stalled-request hints toward the request panel and detailed diagnostics commands
- Added unit coverage for panel rendering and panel toggles
- Updated human-facing docs for the new shortcuts and panel behavior

## Tests

- Ran `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- Result: `187` tests run, `185` passed, `2` skipped, `0` failed

## Remaining

- Make the panel timeline richer and more visually structured
- Consider surfacing approval and whitelist events in the panel
- Continue reducing transient minibuffer-only execution feedback

## Risks

- Chat mode and code mode still duplicate some buffer-local request UI state
- Users may still miss the panel until the execution surface becomes more prominent

## Next Entry

Build the next execution-UX stage on top of the request panel and promote any stable patterns into `20-reference/knowledge/`.
