# Patch Empty File Semantics

- Type: log
- Attention: record
- Status: complete
- Scope: file-editing
- Tags: patch, apply_patch, empty-file, newline

## Summary

Fixed and covered empty-file patch semantics:

- add-file operations with no payload now create a truly empty file instead of a stray newline
- update operations that delete the entire file content now also leave truly empty bytes behind

This closes a byte-level correctness gap where patch output looked correct at a glance but still wrote the wrong file contents.

## Verification

- `emacs -Q -batch -L tests/unit -L lisp/core -l tests/unit/test-helper.el -l tests/unit/test-chat-files.el -f ert-run-tests-batch-and-exit`
- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- Result: `361` passed, `0` skipped, `0` failed
