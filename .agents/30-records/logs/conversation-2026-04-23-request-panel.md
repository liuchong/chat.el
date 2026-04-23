# Log Item

- Type: logs
- Attention: records
- Status: completed
- Scope: request-panel
- Tags: request-panel, diagnostics, ui, code-mode, chat-mode

## Summary

Implemented a dedicated request panel so in-flight execution state no longer has to be rendered inline in the chat transcript.

### Technical Decisions

- Added `lisp/ui/chat-request-panel.el` as the shared rendering surface for request phases, tool events, and stalled-request context
- Reused the existing request diagnostics layer instead of creating another request state model
- Kept panel state buffer-local to the originating chat or code buffer so multiple sessions can coexist cleanly
- Removed inline `Steps:` rendering from assistant messages in both `chat-ui.el` and `chat-code.el`
- Kept `C-c C-s` as the detailed diagnostics entry point and added `C-c C-p` as the lighter-weight request panel toggle

### Completed Work

- Added a request panel module with open, close, toggle, and update helpers
- Wired normal chat to store tool events for the panel and auto-open the panel at request start when configured
- Wired code mode to use the same panel lifecycle and stop inserting step timelines into the conversation body
- Changed stalled-request hints to point users at the panel and diagnostics commands instead of adding transcript noise
- Added tests for panel rendering and buffer toggles
- Updated README and code mode docs to surface the new shortcut and behavior

### Verification

- Ran `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- Result: `187` tests run, `185` passed, `2` skipped, `0` failed
- Skipped tests remained the existing provider-bound Kimi integration checks:
  - `chat-llm-kimi-simple-request`
  - `chat-llm-kimi-streaming-request`

### Remaining

- The panel is still a plain text Emacs surface rather than a richer staged UI
- Approval decisions and whitelist mutations are not yet first-class panel events
- Transport-level timing details such as first-byte latency and curl exit metadata still only exist in lower-level diagnostics paths
