# Streaming UX Upgrade

- Type: log
- Attention: record
- Status: complete
- Scope: code-mode, request-panel, diagnostics
- Tags: streaming, request-panel, diagnostics, auto-follow

## Summary

Upgraded the code-mode streaming experience so request activity feels live, the panel refreshes from diagnostics events, and the conversation buffer follows streamed output more reliably.

## Changes

- added request-diagnostics observers and used them to refresh code-mode live surfaces
- added a periodic live refresh timer so elapsed time and chunk freshness continue updating even between chunk arrivals
- made request panel show live state, last chunk time, chunk age, and last event summary
- replaced the misleading empty-stream placeholder with a live response placeholder based on request phase
- added auto-follow behavior for streamed code-mode output when the user remains near the active response edge
- added regression tests for diagnostics observers, panel live summary rendering, live status refresh, and auto-follow behavior

## Verification

- `emacs -Q -batch -L tests/unit -L lisp/core -L lisp/code -L lisp/ui -l tests/unit/test-helper.el -l tests/unit/test-chat-request-diagnostics.el -l tests/unit/test-chat-request-panel.el -l tests/unit/test-chat-code.el -f ert-run-tests-batch-and-exit`

## Remaining

- the main conversation transcript still does not show a richer step-by-step narrative for non-tool streaming work; it now feels more alive, but it is not yet a full execution timeline
