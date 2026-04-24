# Pure Insert Hunk Compatibility

- Type: logs
- Attention: records
- Status: complete
- Scope: stage
- Tags: patch, unidiff, insert, tests

## Summary

This stage added real compatibility for pure insertion hunks in codex-style unified diffs.

## Changes

- added regression coverage for inserting a new line at the start of a file through a pure insert hunk
- added regression coverage for inserting a new line in the middle of a file through a pure insert hunk
- taught the patch engine to apply hunks with zero source lines by inserting at the header-derived position
- corrected preferred insertion positions for zero-count old ranges so header line numbers map correctly

## Verification

- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- canonical batch regression baseline after this stage: `313` passed, `0` skipped, `0` failed

## Remaining Gap

- repository-wide tests-to-runtime-lines ratio is still far below the requested three-to-one target
