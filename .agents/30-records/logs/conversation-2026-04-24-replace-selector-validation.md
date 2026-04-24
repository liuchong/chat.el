# Replace Selector Validation

- Type: log
- Attention: record
- Status: complete
- Scope: file-editing
- Tags: replace, patch, selectors, validation

## Summary

This stage tightened selector validation for search-replace operations before any matching begins.

- `chat-files--replace-content` now rejects nonpositive `expected_count`
- `chat-files--replace-content` now rejects nonpositive `line_hint`
- `files_patch` inherits the same validation because it reuses the replace core
- regression coverage now locks both direct replace and multi-step search patch behavior to the same stable selector errors

## Verification

- `emacs -Q -batch -L tests/unit -L lisp/core -l tests/unit/test-helper.el -l tests/unit/test-chat-files.el -f ert-run-tests-batch-and-exit`
- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`

## Result

- 376 passed
- 0 skipped
- 0 failed
