# Stage Log 2026-08-07 Agent Kernel Phase 3 (chat-code migration)

- Type: logs
- Attention: records
- Status: final
- Scope: project
- Tags: stage, agent-kernel, chat-code, migration

## Summary

Phase 3 of the unified agent kernel plan: code mode is now a view
over `chat-agent-start`, same as plain chat. Suite: 454 tests, 454
passing. chat-code.el shrank from 2385 to 2271 lines.

## What Landed

- `chat-code--start-agent-run` replaces the streaming and
  non-streaming send paths. Code mode keeps its own contract through
  kernel config: its follow-up text via `:followup-fn`, per-model
  output budget and request timeout via `:request-options`, and the
  longer follow-up timeout via the new `:followup-request-options`.
- The kernel learned `:followup-request-options`: from the second
  turn on, these options merge over `:request-options`, preserving the
  old per-followup timeout behavior.
- `chat-code--make-agent-event-handler` maps kernel events to code
  mode rendering: status line updates, live streaming slots, tool
  events, edit proposals, persistence, and limit reporting. The
  `stopped` status maps to the existing `:tool-loop-limit-reached`
  display contract.
- Deleted: `chat-code--send-streaming`,
  `chat-code--send-non-streaming`, `chat-code--handle-llm-response`,
  `chat-code--finalize-response`,
  `chat-code--resolve-tool-loop-async`, and
  `chat-code--merge-processed-results`.
- `chat-code-cancel` and `chat-code--response-active-p` understand
  the active agent run.

## Behavior Changes

- Per-turn message re-preparation is gone; messages are prepared once
  per run (same as plain chat).
- Tool calls in length-truncated responses are now refused before
  execution in code mode too, via the kernel.

## Test Changes

- Seven code-mode tests rewritten from deleted internals to the new
  view contract; two now exercise the full kernel path end to end
  (persisted assistant message, JSON tool call resolution).
- New kernel test: follow-up request options merge after turn one.

## Verification

- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
  reports 454 results as expected, 0 unexpected.

## Not Done

- Phases 4-8: async shell tool, edit robustness and diff display,
  session JSONL, AGENTS.md ancestor stacking, UI rendering.
- `chat-code--stream-started-p` and
  `chat-code--set-stream-process-sentinel` are now unused by
  production code and remain only for reference; remove later.
