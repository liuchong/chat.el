# Nested Patch Paths

- Type: log
- Attention: record
- Status: complete
- Scope: file-editing
- Tags: patch, apply_patch, paths, directories

## Summary

Added regression coverage for nested-path `apply_patch` behavior:

- add-file operations can create missing parent directories
- move operations can create missing target parent directories
- failed patches that would have added nested files do not leave partial directory trees behind

These checks keep patch planning, mkdir behavior, and atomic failure semantics aligned for more realistic repository layouts.

## Verification

- `emacs -Q -batch -L tests/unit -L lisp/core -l tests/unit/test-helper.el -l tests/unit/test-chat-files.el -f ert-run-tests-batch-and-exit`
- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- Result: `357` passed, `0` skipped, `0` failed
