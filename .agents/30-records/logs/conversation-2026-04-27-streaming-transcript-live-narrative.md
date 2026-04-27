# Streaming Transcript Live Narrative

- Type: log
- Attention: record
- Status: complete
- Scope: code-mode, diagnostics
- Tags: streaming, transcript, diagnostics, tool-loop

## Summary

Extended the streaming UX from request-panel-only visibility into the main code-mode transcript so the active assistant slot now reflects real request state while a reply is still running.

## Changes

- added a shared `chat-request-diagnostics-live-detail` helper so UI surfaces can derive one truthful live narrative from diagnostics and tool events
- updated code-mode transcript rendering to keep visible assistant content separate from a transient `[Live] ...` line
- made the live transcript refresh from diagnostics observer updates, not just streamed text chunks
- hooked tool-call parsing and tool-loop follow-up back into the code-mode transcript so approval and tool-resolution states become visible before final completion
- added regression tests for the shared diagnostics helper and for transcript refresh during tool-loop updates

## Verification

- `emacs -Q -batch -L tests/unit -L lisp/core -L lisp/code -L lisp/tools -L lisp/ui -l tests/unit/test-helper.el -l tests/unit/test-chat-request-diagnostics.el -l tests/unit/test-chat-request-panel.el -l tests/unit/test-chat-code.el -f ert-run-tests-batch-and-exit`

## Remaining

- plain chat still uses the richer request panel and status surfaces, but it does not yet reuse the same transient transcript narrative as code-mode
