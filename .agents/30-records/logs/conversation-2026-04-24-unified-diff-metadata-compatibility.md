# Unified Diff Metadata Compatibility

- Type: logs
- Attention: records
- Status: complete
- Scope: stage
- Tags: patch, unidiff, metadata, tests

## Summary

This stage hardened `apply_patch` against a common class of AI-generated unidiff output by accepting optional metadata lines before update hunks.

## Changes

- accepted standard unified-diff file labels such as `--- old` and `+++ new` before hunks
- accepted git-style metadata such as `diff --git` and `index` before hunks
- tolerated several other patch metadata prefixes without changing the core hunk execution model
- added regression coverage for file-label and git-metadata variants

## Verification

- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- canonical batch regression baseline after this stage: `321` passed, `0` skipped, `0` failed

## Remaining Gap

- repository-wide tests-to-runtime-lines ratio is still far below the requested three-to-one target
