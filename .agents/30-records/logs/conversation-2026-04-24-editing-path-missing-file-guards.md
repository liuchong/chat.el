# Editing Path Missing File Guards

- Type: logs
- Attention: records
- Status: complete
- Scope: stage
- Tags: files, replace, patch, validation, tests

## Summary

This stage extended stable direct-edit validation from directory misuse into missing-file misuse so replace and search-patch entrypoints no longer leak raw file-read errors.

## Changes

- added a shared direct-edit read helper that validates non-directory paths before loading content
- rejected missing files in `files_replace`
- rejected missing files in `files_patch`
- added regression coverage for both direct editing entrypoints keeping missing-file failures stable

## Verification

- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- canonical batch regression baseline after this stage: `347` passed, `0` skipped, `0` failed

## Remaining Gap

- repository-wide tests-to-runtime-lines ratio is still far below the requested three-to-one target
