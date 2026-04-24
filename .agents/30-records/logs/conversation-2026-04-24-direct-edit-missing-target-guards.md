# Direct Edit Missing Target Guards

- Type: logs
- Attention: records
- Status: complete
- Scope: stage
- Tags: files, replace, patch, validation, tests

## Summary

This stage made direct edit flows reject missing targets with stable edit-level errors instead of bubbling up raw file loading failures.

## Changes

- added a shared direct-edit target reader with stable validation
- rejected missing targets in `files_replace`
- rejected missing targets in `files_patch`
- added regression coverage for both direct edit entrypoints

## Verification

- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- canonical batch regression baseline after this stage: `347` passed, `0` skipped, `0` failed

## Remaining Gap

- repository-wide tests-to-runtime-lines ratio is still far below the requested three-to-one target
