# Replace No-op Semantics

- Type: log
- Attention: record
- Status: complete
- Scope: file-editing
- Tags: replace, patch, no-op, errors

## Summary

Changed direct replace semantics so no-op edits fail instead of pretending to succeed:

- literal `files_replace` now rejects replacements that leave content unchanged
- regexp `files_replace` now rejects replacements that leave content unchanged
- `files_patch` inherits the same no-op refusal and remains atomic

This removes one class of false-positive edit results that can mislead automated repair loops.

## Verification

- `emacs -Q -batch -L tests/unit -L lisp/core -l tests/unit/test-helper.el -l tests/unit/test-chat-files.el -f ert-run-tests-batch-and-exit`
- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- Result: `370` passed, `0` skipped, `0` failed
