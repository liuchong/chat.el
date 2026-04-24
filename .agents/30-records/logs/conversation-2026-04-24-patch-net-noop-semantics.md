# Patch Net No-op Semantics

- Type: log
- Attention: record
- Status: complete
- Scope: file-editing
- Tags: patch, no-op, semantics, errors

## Summary

Extended no-op refusal from single-step replace calls to multi-step search patches:

- `files_patch` now rejects patch sequences that temporarily change content but end with the original file bytes again

This removes another false-success path where an automated repair loop could believe a file was changed even though the final bytes were identical.

## Verification

- `emacs -Q -batch -L tests/unit -L lisp/core -l tests/unit/test-helper.el -l tests/unit/test-chat-files.el -f ert-run-tests-batch-and-exit`
- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- Result: `371` passed, `0` skipped, `0` failed
