# Editing Path Directory Guards

- Type: logs
- Attention: records
- Status: complete
- Scope: stage
- Tags: files, replace, patch, write, validation, tests

## Summary

This stage extended stable directory-path validation from `apply_patch` into the direct editing entrypoints so non-patch editing paths stop leaking lower-level directory errors.

## Changes

- rejected directory targets in `files_write`
- rejected directory targets in `files_replace`
- rejected directory targets in `files_patch`
- added regression coverage for each direct editing entrypoint using the same stable directory-path expectation

## Verification

- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- canonical batch regression baseline after this stage: `345` passed, `0` skipped, `0` failed

## Remaining Gap

- repository-wide tests-to-runtime-lines ratio is still far below the requested three-to-one target
