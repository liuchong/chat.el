# Insert At Guards

- Type: logs
- Attention: records
- Status: complete
- Scope: stage
- Tags: files, insert, validation, tests

## Summary

This stage brought `files_insert_at` into the same direct-edit validation path as the other editing entrypoints.

## Changes

- made `files_insert_at` reuse the shared direct-edit target reader
- rejected directory targets in `files_insert_at`
- rejected missing targets in `files_insert_at`
- added regression coverage for both failure shapes

## Verification

- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- canonical batch regression baseline after this stage: `349` passed, `0` skipped, `0` failed

## Remaining Gap

- repository-wide tests-to-runtime-lines ratio is still far below the requested three-to-one target
