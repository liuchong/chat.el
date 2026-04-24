# Hunk Line Validation

- Type: logs
- Attention: records
- Status: complete
- Scope: stage
- Tags: patch, unidiff, validation, tests

## Summary

This stage tightened `apply_patch` input validation so malformed hunk payload lines fail early instead of slipping into the patch engine.

## Changes

- validated that update-hunk payload lines use unified-diff prefixes ` `, `+`, or `-`
- rejected malformed plain-text hunk payload lines before patch application
- rejected ndiff-style helper lines such as `? ...`, which are not valid unified-diff payloads
- added regression coverage for both malformed-line classes

## Verification

- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- canonical batch regression baseline after this stage: `323` passed, `0` skipped, `0` failed

## Remaining Gap

- repository-wide tests-to-runtime-lines ratio is still far below the requested three-to-one target
