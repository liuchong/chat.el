# Patch Eof Update And Replace Narrowing

- Type: logs
- Attention: records
- Status: complete
- Scope: stage
- Tags: patch, replace, eof, tests

## Summary

This stage fixed update-patch EOF handling and added denser regression coverage for replace narrowing behavior.

## Changes

- made update-style `apply_patch` honor `*** End of File` when the patch removes a trailing newline from the rewritten file
- added regression coverage for that EOF-removal path
- added regression coverage showing that `files_replace` can use `line_hint` to narrow an otherwise ambiguous match
- added regression coverage showing that `expected_count` validates the already line-filtered match set

## Verification

- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- canonical batch regression baseline after this stage: `311` passed, `0` skipped, `0` failed

## Remaining Gap

- repository-wide tests-to-runtime-lines ratio is still far below the requested three-to-one target
