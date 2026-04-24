# Patch Header Drift And Directory Validation

- Type: logs
- Attention: records
- Status: complete
- Scope: stage
- Tags: patch, unidiff, validation, atomicity, tests

## Summary

This stage hardened `apply_patch` in two places that still produced real production risk under AI-generated diffs: inaccurate hunk header counts and directory-path misuse.

## Changes

- used actual hunk payload counts for update line-delta tracking instead of blindly trusting header counts
- added regression coverage showing later hunks still land correctly after earlier header drift
- rejected directory paths with stable verification errors in add, update, and delete planning paths
- kept add-followed-by-delete failure atomic when a later directory misuse is detected

## Verification

- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- canonical batch regression baseline after this stage: `342` passed, `0` skipped, `0` failed

## Remaining Gap

- repository-wide tests-to-runtime-lines ratio is still far below the requested three-to-one target
