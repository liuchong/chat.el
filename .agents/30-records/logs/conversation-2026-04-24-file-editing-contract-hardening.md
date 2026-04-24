# File Editing Contract Hardening

- Type: log
- Attention: record
- Status: complete
- Scope: file-editing
- Tags: replace, apply-patch, tests, hardening

## Summary

Hardened file-editing edge contracts around malformed tool arguments and malformed patch envelopes.

## Changes

- `chat-files--replace-content` now rejects non-string search and replacement values with stable `Replace failed:` errors
- `chat-files--parse-apply-patch` now requires both `*** Begin Patch` and `*** End Patch`
- added regression coverage for:
  - non-string replace arguments
  - empty patch lists
  - missing patch end envelope
  - empty and whitespace-only patch text
  - illegal top-level `*** Move to:` lines
  - unique-match fallback when hunk header start positions drift

## Verification

- `emacs -Q -batch -L tests/unit -L lisp/core -l tests/unit/test-helper.el -l tests/unit/test-chat-files.el -f ert-run-tests-batch-and-exit`
- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`

## Result

- 390 passed
- 0 skipped
- 0 failed
