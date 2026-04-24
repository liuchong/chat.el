# Patch Conflict Semantics

- Type: log
- Attention: record
- Status: complete
- Scope: file-editing
- Tags: patch, apply_patch, conflicts, errors

## Summary

Added regression coverage for three high-frequency `apply_patch` conflict paths:

- add-file against an existing target
- delete-file against a missing target
- move-only update against a missing source

These checks keep verification errors stable and ensure conflict refusals stay atomic instead of leaking lower-level file-system behavior.

## Verification

- `emacs -Q -batch -L tests/unit -L lisp/core -l tests/unit/test-helper.el -l tests/unit/test-chat-files.el -f ert-run-tests-batch-and-exit`
- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- Result: `367` passed, `0` skipped, `0` failed
