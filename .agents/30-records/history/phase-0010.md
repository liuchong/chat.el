# Phase 0010

- Type: progress
- Attention: records
- Status: completed
- Scope: status-governance
- Tags: phase, status, governance, emacs

## Goal

Define and enforce a rule for what can appear in persistent native status surfaces so the UI stays useful instead of becoming an activity wall.

## Completed

- Added shared status-surface eligibility helpers
- Restricted persistent status surfaces to blocking approval states
- Kept transient thinking and ordinary tool-call activity out of persistent status areas
- Added regression coverage for both positive and negative status-surface cases
- Updated reference knowledge for future contributors

## Tests

- Ran `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- Result: `200` tests run, `198` passed, `2` skipped, `0` failed

## Remaining

- Decide whether any other blocking state should be added to the persistent status rule
- Continue pushing detailed transient activity toward the request panel instead of persistent UI chrome

## Risks

- A future feature may try to bypass the shared rule and reintroduce status noise
- The shared rule is simple by design and should stay small unless a new blocking state is clearly justified

## Next Entry

Extend the shared status rule only when a new state clearly changes the user's next action.
