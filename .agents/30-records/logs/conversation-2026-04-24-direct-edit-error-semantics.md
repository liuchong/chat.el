# Direct Edit Error Semantics

- Type: logs
- Attention: records
- Status: complete
- Scope: stage
- Tags: files, errors, validation, tests

## Summary

This stage separated direct-edit errors from patch-engine errors so non-patch editing flows stop using `apply_patch`-style failure wording.

## Changes

- added a direct-edit-specific directory validation helper
- made `files_write` use direct-edit path semantics
- kept `files_replace`, `files_patch`, and `files_insert_at` on the same direct-edit wording
- preserved `apply_patch verification failed` wording for patch-engine validation

## Verification

- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- canonical batch regression baseline after this stage: `349` passed, `0` skipped, `0` failed

## Remaining Gap

- repository-wide tests-to-runtime-lines ratio is still far below the requested three-to-one target
