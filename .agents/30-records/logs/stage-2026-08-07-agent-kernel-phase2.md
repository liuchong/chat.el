# Stage Log 2026-08-07 Agent Kernel Phase 2 (chat-ui migration)

- Type: logs
- Attention: records
- Status: final
- Scope: project
- Tags: stage, agent-kernel, chat-ui, migration

## Summary

Phase 2 of the unified agent kernel plan: plain chat is now a view
over `chat-agent-start`. The duplicated tool loops and response
handlers in chat-ui are deleted. Suite: 453 tests, 453 passing.
chat-ui.el shrank from 1291 to 1065 lines; net -500/+298 across the
phase including tests.

## What Landed

- `chat-ui--start-agent-run` is the single send path for both
  transports; `chat-ui--get-response-sync` and
  `chat-ui--get-response-streaming` are thin wrappers choosing
  `sync` or `stream`.
- `chat-ui--make-agent-event-handler` maps kernel events to the
  existing rendering: stream-chunk, tool-event, response, followup
  (diagnostics tool-loop-step records), and agent-end (finalize,
  cancel, and error rendering). The stopped status now surfaces the
  tool loop limit in plain chat, closing the drift where only code
  mode reported it.
- Deleted: `chat-ui--resolve-tool-loop` (dead sync loop),
  `chat-ui--resolve-tool-loop-async`,
  `chat-ui--handle-response-success`,
  `chat-ui--render-stream-start-error`,
  `chat-ui--message-exists-p`, and
  `chat-ui--merge-processed-results`.
- `chat-ui-cancel-response` cancels the active agent run first and
  keeps the legacy handle/process path as fallback.
- `chat-ui--response-active-p` also checks the active agent run.
- Diagnostics traces are now bounded: events are stored newest first,
  capped by `chat-request-diagnostics-max-events` (default 200), and
  snapshots reverse back to chronological order. This removes the
  O(N^2) append per stream chunk and the unbounded memory growth.
- `chat-ui-tool-loop-max-steps` is preserved and passed to the kernel
  as `:max-steps`, so existing user configuration keeps working.

## Test Changes

- Removed three tests that exercised the deleted loop functions; their
  contracts are covered by test-chat-agent.el kernel tests.
- `chat-ui-get-response-sync-uses-async-request-path` now asserts the
  run completed instead of a leftover request handle.
- Added: sync/stream transport selection tests and the diagnostics
  cap test.

## Verification

- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
  reports 453 results as expected, 0 unexpected.

## Not Done

- Phases 3-8: chat-code migration, async shell tool, edit robustness
  and diff display, session JSONL, AGENTS.md ancestor stacking, UI
  rendering.
- Streaming runs no longer store a raw request payload on the
  assistant message (the old path kept the first request JSON).
