# Hunk Header And Empty Update Validation

- Type: logs
- Attention: records
- Status: complete
- Scope: stage
- Tags: patch, unidiff, validation, tests

## Summary

This stage tightened `apply_patch` structure validation around hunk headers and empty update blocks without regressing shorthand codex patch compatibility.

## Changes

- rejected malformed hunk headers before patch application
- rejected update blocks that contain neither hunks nor a move target
- preserved compatibility with bare `@@` shorthand headers that are common in codex-style patch output
- added regression coverage for malformed-header and empty-update failure paths

## Verification

- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- canonical batch regression baseline after this stage: `325` passed, `0` skipped, `0` failed

## Remaining Gap

- repository-wide tests-to-runtime-lines ratio is still far below the requested three-to-one target
