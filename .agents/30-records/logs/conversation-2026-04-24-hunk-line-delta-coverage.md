# Hunk Line Delta Coverage

- Type: logs
- Attention: records
- Status: complete
- Scope: stage
- Tags: patch, unidiff, hunk, tests

## Summary

This stage tightened confidence in sequential hunk placement by covering insert/delete line-delta drift scenarios.

## Changes

- added regression coverage for a later update hunk landing after an earlier pure insert hunk
- added regression coverage for a later update hunk landing after an earlier pure delete hunk
- verified that the current line-delta logic preserves header-based placement across those two common multi-hunk shapes

## Verification

- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- canonical batch regression baseline after this stage: `317` passed, `0` skipped, `0` failed

## Remaining Gap

- repository-wide tests-to-runtime-lines ratio is still far below the requested three-to-one target
