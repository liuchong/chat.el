# Stage Plan

- Type: progress
- Attention: active
- Status: active
- Scope: planning
- Tags: stage, plan, approval-status

## Goal

Keep pending approvals continuously visible through native Emacs status surfaces instead of relying only on prompt text or one-shot echo-area hints.

## Completed

- Added pending approval extraction helpers for chat mode and code mode
- Updated code mode `header-line` and mode line to show a persistent approval marker when a risky tool is waiting for approval
- Updated chat UI top status line to show `Approval Pending` and the tool name when approval is waiting
- Kept the implementation fully Emacs-native without inserting extra transcript content
- Added regression tests for chat status-line approval rendering and code mode header/mode line approval rendering
- Updated stage records and human-facing docs for the status-surfacing pass

## Tests

- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- Result: `198` tests run, `196` passed, `2` skipped, `0` failed

## Remaining

- Decide whether pending approvals need even stronger modeline/header emphasis or whether the current balance is enough
- Continue improving visibility without degrading signal-to-noise in normal editing

## Risks

- Chat mode and code mode still maintain separate UI state around the same diagnostics lifecycle
- More persistent approval status can become noisy if too many transient states are promoted into status surfaces

## Next Entry

Record the next execution-UX stage in `.agents/30-records/` and distill durable native-Emacs status-surface patterns into `20-reference/knowledge/`.
