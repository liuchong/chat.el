# Patch Failure Family

- Type: log
- Attention: record
- Status: complete
- Scope: file-editing
- Tags: patch, apply_patch, errors, diagnostics

## Summary

Normalized more apply-time patch failures into the stable `apply_patch verification failed: ...` family:

- ambiguous repeated-context hunks now have explicit regression coverage
- invalid pure-insert locations now use the same `Patch hunk could not be applied` family instead of a one-off message

This keeps more patch failures machine-classifiable for retry and recovery logic.

## Verification

- `emacs -Q -batch -L tests/unit -L lisp/core -l tests/unit/test-helper.el -l tests/unit/test-chat-files.el -f ert-run-tests-batch-and-exit`
- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- Result: `359` passed, `0` skipped, `0` failed
