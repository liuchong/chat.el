# Chained Patch Paths

- Type: log
- Attention: record
- Status: complete
- Scope: file-editing
- Tags: patch, apply_patch, moves, chaining

## Summary

Added regression coverage for chained path reuse inside one `apply_patch` payload:

- add then delete on the same path
- move then delete the moved path
- chained moves across an intermediate path

These checks verify that planned patch state and final disk writes stay aligned even when one patch reuses paths multiple times in sequence.

## Verification

- `emacs -Q -batch -L tests/unit -L lisp/core -l tests/unit/test-helper.el -l tests/unit/test-chat-files.el -f ert-run-tests-batch-and-exit`
- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- Result: `364` passed, `0` skipped, `0` failed
