# Stage Plan

- Type: progress
- Attention: active
- Status: active
- Scope: planning
- Tags: stage, plan, request-panel

## Goal

Move request progress visibility out of the chat transcript and into a dedicated structured panel shared by chat mode and code mode.

## Completed

- Added `lisp/ui/chat-request-panel.el` as a shared request panel module
- Wired chat mode and code mode to capture tool events for the panel and stop rendering step timelines inline in assistant output
- Added `C-c C-p` panel toggles for both normal chat and code mode buffers
- Switched stalled-request hints to point users at the request panel and detailed diagnostics instead of inserting extra transcript noise
- Updated tests to cover request panel rendering and panel toggles
- Updated human-facing docs to describe the new panel shortcut and request-status flow

## Tests

- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- Result: `187` tests run, `185` passed, `2` skipped, `0` failed

## Remaining

- Reduce the remaining plain-text minibuffer status flow into a more coherent persistent execution surface
- Consider whether approval prompts and shell whitelist management should also project into the request panel

## Risks

- Chat mode and code mode still maintain separate UI state around the same diagnostics lifecycle
- The panel is functional but not yet a complete execution timeline product

## Next Entry

Record the next execution-UX stage in `.agents/30-records/` and distill any durable panel patterns into `20-reference/knowledge/`.
