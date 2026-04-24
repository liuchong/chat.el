# Regexp Narrowing And Move Only Coverage

- Type: logs
- Attention: records
- Status: complete
- Scope: stage
- Tags: replace, patch, regexp, move, tests

## Summary

This stage expanded coverage around two more realistic AI editing shapes: regexp replacements constrained by line filters and move-only patch updates.

## Changes

- added regression coverage for regexp replace-all under a line hint
- added regression coverage for regexp `expected_count` success after line filtering
- added regression coverage for move-only `apply_patch` updates that rename a file without content hunks
- confirmed these paths against the current runtime without widening behavior unnecessarily

## Verification

- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- canonical batch regression baseline after this stage: `331` passed, `0` skipped, `0` failed

## Remaining Gap

- repository-wide tests-to-runtime-lines ratio is still far below the requested three-to-one target
