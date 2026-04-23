# Stage Plan

- Type: progress
- Attention: active
- Status: active
- Scope: planning
- Tags: stage, plan, status-governance

## Goal

Define and enforce which tool states deserve persistent native status surfaces so the UI does not devolve into an activity wall.

## Completed

- Added shared `lisp/ui/chat-status.el` to define persistent-status eligibility rules
- Centralized the rule that only blocking `approval-pending` events qualify for persistent status surfaces
- Updated chat mode and code mode to consume the shared status rule instead of open-coding local checks
- Added regression tests proving non-blocking events like `thinking` and `tool-call` do not appear in persistent status surfaces
- Updated stage records and reference docs for the status-governance pass

## Tests

- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- Result: `200` tests run, `198` passed, `2` skipped, `0` failed

## Remaining

- Decide whether any future blocking state besides approvals deserves persistent status treatment
- Keep detailed transient activity inside the request panel instead of leaking it into persistent surfaces

## Risks

- Chat mode and code mode still maintain separate rendering implementations even though status eligibility is now shared
- Future contributors may still be tempted to bypass the shared status rule for convenience

## Next Entry

Record the next execution-UX stage in `.agents/30-records/` and extend the shared status rule only if a new state truly blocks user action.
