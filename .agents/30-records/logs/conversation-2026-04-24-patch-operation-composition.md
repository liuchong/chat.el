# Patch Operation Composition

- Type: log
- Attention: record
- Status: complete
- Scope: file-editing
- Tags: patch, apply_patch, tests, composition

## Summary

Added regression coverage for multi-operation `apply_patch` sequences that models commonly emit while iterating on the same file set in one patch:

- delete then add on the same path
- add then update on the same path
- move then update the new path
- move then recreate the old path

These paths now have canonical regression protection so patch planning and final disk writes stay aligned when multiple operations target the same logical file set in sequence.

## Verification

- `emacs -Q -batch -L tests/unit -L lisp/core -l tests/unit/test-helper.el -l tests/unit/test-chat-files.el -f ert-run-tests-batch-and-exit`
- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- Result: `354` passed, `0` skipped, `0` failed
