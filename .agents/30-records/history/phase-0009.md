# Phase 0009

- Type: progress
- Attention: records
- Status: completed
- Scope: approval-status
- Tags: phase, approval, status, emacs

## Goal

Make pending approvals continuously visible through native Emacs status surfaces instead of relying only on prompt text and transient echo-area hints.

## Completed

- Added pending approval extraction helpers in chat mode and code mode
- Added code mode header-line and mode line approval indicators
- Added chat UI top status-line approval indicator
- Kept the implementation Emacs-native and avoided transcript pollution
- Added regression tests for status rendering in both chat mode and code mode

## Tests

- Ran `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- Result: `198` tests run, `196` passed, `2` skipped, `0` failed

## Remaining

- Decide whether the current status prominence is sufficient or whether pending approvals need stronger emphasis
- Continue keeping approval visibility improvements aligned with normal editing ergonomics

## Risks

- Persistent approval indicators could become noisy if too many other transient states are promoted the same way
- Chat mode and code mode still duplicate some status rendering logic

## Next Entry

Use the persistent approval status baseline to decide the next Emacs-native UX improvement.
