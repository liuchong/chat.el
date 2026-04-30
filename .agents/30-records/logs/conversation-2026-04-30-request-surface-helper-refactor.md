# Request Surface Helper Refactor

- Type: log
- Attention: record
- Status: complete
- Scope: request-surface, chat-ui, code-mode
- Tags: refactor, request-surface, diagnostics, reuse

## Summary

Extracted the shared live-request surface mechanics that were duplicated between `chat-ui` and `code-mode` into one helper module, without collapsing their different status and transcript semantics into a larger controller.

## Changes

- added `lisp/ui/chat-request-surface.el` for shared request-surface helpers
- centralized shared logic for diagnostics buffer observers, live refresh timers, request-panel refresh gating, approval hint deduping, live narrative formatting, and tool-target extraction
- switched `chat-ui` and `code-mode` to reuse those helpers while keeping their own state ownership and render differences
- added helper-level tests so future UI refactors can validate the common contract directly instead of relying only on indirect mode tests

## Verification

- `emacs -Q -batch --eval '(setq load-prefer-newer t)' -L tests/unit -L lisp/core -L lisp/ui -L lisp/code -L lisp/tools -l tests/unit/test-helper.el -l tests/unit/test-chat-request-surface.el -l tests/unit/test-chat-request-diagnostics.el -l tests/unit/test-chat-ui.el -l tests/unit/test-chat-code.el -f ert-run-tests-batch-and-exit`
- `emacs -Q -batch -L lisp/core -L lisp/ui -L lisp/code -L lisp/tools -L lisp/llm -f batch-byte-compile lisp/ui/chat-request-surface.el lisp/ui/chat-ui.el lisp/code/chat-code.el`
- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`

## Remaining

- `chat-code.el` still has pre-existing compile warnings outside this refactor, including one long custom docstring and one free-variable warning in `chat-code-from-chat`
