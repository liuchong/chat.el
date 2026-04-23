# Stage Plan

- Type: progress
- Attention: active
- Status: active
- Scope: planning
- Tags: stage, plan, approval-panel

## Goal

Make approval and whitelist decisions visible in the shared request panel so execution flow no longer splits between the panel and opaque minibuffer prompts.

## Completed

- Extended `chat-approval.el` approval events with command context, risk level, and explicit decision options
- Added whitelist mutation events when a shell command is promoted into the allowlist
- Updated `chat-request-panel.el` to render approval choices, command context, and whitelist updates as structured multi-line entries
- Kept whitelisted shell executions attached to command context in `chat-tool-caller.el`
- Added and updated tests for approval observer payloads, request-panel approval rendering, and whitelisted shell event propagation
- Updated stage records and human-facing status docs for the richer approval flow

## Tests

- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- Result: `191` tests run, `189` passed, `2` skipped, `0` failed

## Remaining

- Reduce the remaining plain-text minibuffer status flow into a more coherent persistent execution surface
- Decide whether approval input itself should stay Emacs-native or move into a more explicit panel action flow

## Risks

- Chat mode and code mode still maintain separate UI state around the same diagnostics lifecycle
- Approval state is now visible, but decision input still depends on minibuffer interaction

## Next Entry

Record the next execution-UX stage in `.agents/30-records/` and distill durable approval-flow patterns into `20-reference/knowledge/`.
