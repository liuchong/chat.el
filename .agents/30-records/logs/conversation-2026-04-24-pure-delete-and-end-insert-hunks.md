# Pure Delete And End Insert Hunks

- Type: logs
- Attention: records
- Status: complete
- Scope: stage
- Tags: patch, unidiff, delete, insert, tests

## Summary

This stage expanded patch-engine coverage around two more common AI-generated unified diff shapes: pure deletion hunks and pure insertion at file end.

## Changes

- added regression coverage for a pure delete hunk that removes a line without replacement content
- added regression coverage for a pure insert hunk that appends a line at file end
- verified these paths against the existing patch-engine implementation without widening the runtime surface unnecessarily

## Verification

- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- canonical batch regression baseline after this stage: `315` passed, `0` skipped, `0` failed

## Remaining Gap

- repository-wide tests-to-runtime-lines ratio is still far below the requested three-to-one target
