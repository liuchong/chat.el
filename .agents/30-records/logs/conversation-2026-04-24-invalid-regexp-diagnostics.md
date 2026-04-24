# Invalid Regexp Diagnostics

- Type: logs
- Attention: records
- Status: complete
- Scope: stage
- Tags: replace, regexp, diagnostics, tests

## Summary

This stage hardened invalid-regexp handling so AI retries can distinguish bad search syntax from file-state problems.

## Changes

- wrapped regexp parsing failures behind a stable `Replace failed: invalid regexp ...` error
- added regression coverage showing `files_replace` leaves files unchanged on invalid regexp input
- added regression coverage showing `files_patch` leaves files unchanged on invalid regexp input
- kept the runtime surface otherwise unchanged

## Verification

- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- canonical batch regression baseline after this stage: `333` passed, `0` skipped, `0` failed

## Remaining Gap

- repository-wide tests-to-runtime-lines ratio is still far below the requested three-to-one target
