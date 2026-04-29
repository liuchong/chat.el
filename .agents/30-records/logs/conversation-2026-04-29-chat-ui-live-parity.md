# Chat UI Live Parity

- Type: log
- Attention: record
- Status: complete
- Scope: chat-ui, request-diagnostics, tool-followup
- Tags: chat-ui, streaming, diagnostics, follow-up

## Summary

Brought plain `chat-ui` onto the same live request baseline that had already been validated in `code-mode`, without introducing a larger shared controller abstraction.

## Changes

- added diagnostics observer and refresh-timer handling to `chat-ui` so transcript and request-panel surfaces refresh while a request is still active
- added a transient `[Live] ...` narrative line to the active assistant slot in plain chat, reusing `chat-request-diagnostics-live-detail`
- unified streaming rendering with the same response-state path used by non-streaming and tool-event updates
- tracked recent single-file tool targets in plain chat session metadata and fed that hint back into later tool-enabled follow-up prompts
- hardened `chat-ui` live rendering so diagnostics refreshes stay safe even if no active session object is currently bound
- added regression coverage for plain-chat live detail rendering, diagnostics-driven transcript refresh, recent file-target tracking, and follow-up prompt hints

## Verification

- `emacs -Q -batch --eval '(setq load-prefer-newer t)' -L tests/unit -L lisp/core -L lisp/ui -L lisp/tools -l tests/unit/test-helper.el -l tests/unit/test-chat-request-diagnostics.el -l tests/unit/test-chat-ui.el -l tests/unit/test-chat-ui-streaming.el -f ert-run-tests-batch-and-exit`
- `emacs -Q -batch -L lisp/core -L lisp/ui -L lisp/tools -L lisp/llm -f batch-byte-compile lisp/ui/chat-ui.el`
- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`

## Remaining

- `chat-ui.el` still has a few pre-existing unused lexical variable warnings in unrelated helper paths, but no new compile-time structural warnings remain from this parity work
