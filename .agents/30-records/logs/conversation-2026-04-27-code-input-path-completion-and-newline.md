# Code Input Path Completion And Newline

- Type: log
- Attention: record
- Status: complete
- Scope: code-mode, request-panel, input
- Tags: code-mode, completion, newline, request-panel

## Summary

Improved the code-mode input surface with path-aware completion, multiline newline insertion, and more visible directory approval context.

## Changes

- added automatic path completion in the code-mode input area for absolute and project-relative path tokens
- added `chat-code-insert-newline` and bound `S-RET` to insert a newline without sending
- updated code-mode native help to mention `S-RET`, path completion, and directory-scoped file-write approvals
- updated the request panel to render directory approval scope on pending and accepted approval events
- added regression tests for path completion, auto-trigger behavior, multiline input, and request-panel directory rendering

## Verification

- `emacs -Q -batch -L tests/unit -L lisp/core -L lisp/code -L lisp/ui -l tests/unit/test-helper.el -l tests/unit/test-chat-code.el -l tests/unit/test-chat-request-panel.el -f ert-run-tests-batch-and-exit`

## Remaining

- path completion currently focuses on path-like tokens that already contain an absolute marker or slash; bare file-name token completion is still intentionally out of scope
