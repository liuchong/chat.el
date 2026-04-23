# Stage Plan

- Type: progress
- Attention: active
- Status: active
- Scope: planning
- Tags: stage, plan, approval-discoverability

## Goal

Keep the shared request panel as the visible approval surface while making approval shortcuts discoverable in native Emacs prompts and immediate status feedback.

## Completed

- Added prompt-level shortcut hints in `chat-approval.el`
- Added a shared `chat-approval-pending-message` helper so approval guidance stays consistent
- Updated chat mode and code mode to announce pending approval shortcuts through native `message` feedback the first time a pending approval appears
- Kept the request panel and prompt guidance aligned without adding transcript noise or custom widget UI
- Added regression tests for prompt hints and native approval hint generation in chat mode and code mode
- Updated stage records and human-facing docs for the discoverability pass

## Tests

- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- Result: `196` tests run, `194` passed, `2` skipped, `0` failed

## Remaining

- Reduce the remaining plain-text minibuffer status flow into a more coherent persistent execution surface
- Decide whether the next step should be panel-local button interaction or stronger status-line level affordances that stay fully Emacs-native

## Risks

- Chat mode and code mode still maintain separate UI state around the same diagnostics lifecycle
- Approval is now easier to discover, but still fundamentally depends on minibuffer interaction staying stable

## Next Entry

Record the next execution-UX stage in `.agents/30-records/` and distill durable native-Emacs approval guidance patterns into `20-reference/knowledge/`.
