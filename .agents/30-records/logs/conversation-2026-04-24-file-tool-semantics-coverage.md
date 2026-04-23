# File Tool Semantics Coverage

- Type: logs
- Attention: records
- Status: complete
- Scope: stage
- Tags: files, tests, regression

## Summary

This stage expanded direct regression coverage around the base `chat-files` helpers without changing runtime behavior.

## Changes

- added coverage for:
  - partial reads with offset and limit
  - size-limit rejection on reads
  - directory existence reporting
  - non-recursive filename filtering
  - move and copy overwrite rejection
  - recursive directory deletion
  - nested directory creation with parents

## Verification

- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- canonical batch regression baseline after this stage: `286` passed, `0` skipped, `0` failed

## Remaining Gap

- repository-wide tests-to-runtime-lines ratio is still far below the requested three-to-one target
