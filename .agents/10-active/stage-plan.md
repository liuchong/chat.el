# Stage Plan

- Type: progress
- Attention: active
- Status: active
- Scope: planning
- Tags: stage, plan, approval-shortcuts

## Goal

Keep the shared request panel as the visible approval surface while adding fast approval shortcuts that work with the existing synchronous prompt flow.

## Completed

- Added pending approval state and decision commands in `chat-approval.el`
- Added approval shortcut hints to approval events so the request panel can teach the active decision path
- Installed approval shortcut bindings into the minibuffer prompt used by `completing-read`
- Updated request panel rendering to show the shortcut action line for pending approvals
- Added regression tests for approval commands, approval event action hints, and panel rendering of shortcut guidance
- Updated stage records and human-facing docs for the shortcut-based approval flow

## Tests

- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- Result: `193` tests run, `191` passed, `2` skipped, `0` failed

## Remaining

- Reduce the remaining plain-text minibuffer status flow into a more coherent persistent execution surface
- Decide whether the next step should be panel-local button interaction or simply stronger shortcut discoverability in the main chat buffers

## Risks

- Chat mode and code mode still maintain separate UI state around the same diagnostics lifecycle
- Approval is faster now, but still fundamentally depends on minibuffer interaction staying stable

## Next Entry

Record the next execution-UX stage in `.agents/30-records/` and distill durable shortcut and approval-flow patterns into `20-reference/knowledge/`.
