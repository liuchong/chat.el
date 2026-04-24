# Unidiff Compatibility

- Type: logs
- Attention: records
- Status: complete
- Scope: stage
- Tags: patch, unidiff, tests

## Summary

This stage hardened the codex-style `apply_patch` engine toward AI-friendly unidiff compatibility.

## Changes

- added regression coverage for:
  - `*** End of File` markers
  - repeated source blocks resolved by hunk headers
  - multiple hunks in one file
- parsed hunk header metadata and used it to disambiguate repeated source context during patch application
- accepted codex-compatible EOF markers inside update hunks

## Verification

- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- canonical batch regression baseline after this stage: `304` passed, `0` skipped, `0` failed

## Remaining Gap

- repository-wide tests-to-runtime-lines ratio is still far below the requested three-to-one target
