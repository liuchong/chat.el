# Line-Scoped Replace Diagnostics

- Type: log
- Attention: record
- Status: complete
- Scope: file-editing
- Tags: replace, patch, line-hint, diagnostics

## Summary

This stage tightened the AI-facing failure diagnostics for line-filtered search-replace flows.

- `chat-files--replace-content` now carries `line_hint` scope into no-match failures
- count mismatches now report the filtered line scope instead of a generic file-wide message
- ambiguous same-line matches now keep the line number in the refusal text
- `files_patch` inherits the same stable line-scoped diagnostics because it reuses the same replace core

## Verification

- `emacs -Q -batch -L tests/unit -L lisp/core -l tests/unit/test-helper.el -l tests/unit/test-chat-files.el -f ert-run-tests-batch-and-exit`
- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`

## Result

- 373 passed
- 0 skipped
- 0 failed
