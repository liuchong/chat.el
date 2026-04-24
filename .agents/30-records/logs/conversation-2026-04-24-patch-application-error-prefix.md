# Patch Application Error Prefix

- Type: logs
- Attention: records
- Status: complete
- Scope: stage
- Tags: patch, errors, validation, tests

## Summary

This stage normalized patch application failures so parser-time and apply-time failures now share the same `apply_patch verification failed` prefix.

## Changes

- added a wrapper that normalizes patch application errors
- preserved already-prefixed parser and verification errors
- prefixed hunk application failures such as `Patch hunk could not be applied`
- added regression coverage for apply-time hunk failure wording

## Verification

- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- canonical batch regression baseline after this stage: `350` passed, `0` skipped, `0` failed

## Remaining Gap

- repository-wide tests-to-runtime-lines ratio is still far below the requested three-to-one target
