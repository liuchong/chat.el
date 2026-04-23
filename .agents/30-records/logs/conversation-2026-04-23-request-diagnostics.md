# Imported Log

- Type: logs
- Attention: records
- Status: imported
- Scope: legacy-session
- Tags: imported, legacy, ai-context

## Original Record

# Requirements

- Add a real request diagnostics feature for cases where the UI stays on `Getting response from AI...` without visible progress
- Keep the design modular instead of scattering more state across `chat-ui.el`, `chat-code.el`, `chat-llm.el`, and `chat-stream.el`
- Expose actionable status to users during both normal chat and code mode
- Add tests for the new request lifecycle behavior

# Technical Decisions

- Added a shared `chat-request-diagnostics.el` module as the single place for request trace state, snapshots, stall detection, and diagnostics buffer rendering
- Kept lifecycle event production in transport layers:
  - `chat-llm.el` records async dispatch, timeout, response, error, and cancellation
  - `chat-stream.el` records stream start, chunk progress, and stream processing errors
- Kept mode-specific state in the UI layers:
  - `chat-ui.el` tracks the active diagnostics request id for normal chat buffers
  - `chat-code.el` tracks the active diagnostics request id for code mode buffers
- Added explicit interactive status commands instead of relying on transient minibuffer messages:
  - `chat-show-current-request-status`
  - `chat-code-show-current-request-status`
- Added one-shot stalled-request hints driven by the shared diagnostics layer instead of duplicating timeout heuristics in each UI path

# Completed Work

- Added `lisp/core/chat-request-diagnostics.el`
- Wired async request diagnostics into `lisp/llm/chat-llm.el`
- Wired streaming diagnostics into `lisp/core/chat-stream.el`
- Added current-request tracking, stalled-request hints, cleanup, and status commands in `lisp/ui/chat-ui.el`
- Added the same diagnostics flow and `C-c C-s` status command in `lisp/code/chat-code.el`
- Updated mode keybindings so both chat and code mode can open the active request diagnostics buffer
- Added or updated unit coverage for:
  - diagnostics snapshots and stall messages
  - async request diagnostics propagation
  - stream chunk diagnostics
  - chat UI diagnostics command and request-id propagation
  - code mode diagnostics command and request-id propagation

# Pending Work

- The current UI still renders stalled hints as inserted system text, not as a dedicated side panel or structured request timeline
- Request diagnostics are in-memory only and are not yet exportable for bug reports
- The current implementation does not yet surface provider-specific lower-level transport metadata such as curl exit codes or first-byte timing

# Key Code Paths

- `lisp/core/chat-request-diagnostics.el`
- `lisp/llm/chat-llm.el`
- `lisp/core/chat-stream.el`
- `lisp/ui/chat-ui.el`
- `lisp/code/chat-code.el`
- `tests/unit/test-chat-request-diagnostics.el`
- `tests/unit/test-chat-llm.el`
- `tests/unit/test-chat-stream.el`
- `tests/unit/test-chat-ui.el`
- `tests/unit/test-chat-code.el`

# Verification

- Ran `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- Result: `183` tests run, `181` passed, `2` skipped, `0` failed
- Skipped tests remained the existing live Kimi request checks:
  - `chat-llm-kimi-simple-request`
  - `chat-llm-kimi-streaming-request`

# Issues Encountered

- The first pass pushed `:request-id nil` into some option plists, which broke existing tests expecting the old exact plist shape; fixed by only adding the key when a request id exists
- Immediate success callbacks in async request tests exposed that diagnostics event order cannot assume the last event is always the response event; the tests were updated to validate the event timeline semantically instead
- `chat-ui--resolve-tool-loop-async` briefly had mismatched parentheses after refactoring the request option assembly; this was caught by batch loading and fixed before the final verification run
- Added a new troubleshooting entry because the event ordering issue is a real maintenance hazard
