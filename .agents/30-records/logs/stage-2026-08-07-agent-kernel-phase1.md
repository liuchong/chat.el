# Stage Log 2026-08-07 Agent Kernel (Phase 1)

- Type: logs
- Attention: records
- Status: final
- Scope: project
- Tags: stage, agent-kernel, pi-port, events

## Summary

Phase 1 of the approved plan "unified event-driven kernel"
(~/.kimi/plans/moon-girl-black-widow-raven.md): a new UI agnostic
agent run loop modeled on pi's agent-loop. Pure addition, no UI
changes. Suite: 453 tests, 453 passing (443 baseline plus 10 new).

## What Landed

- New `lisp/core/chat-agent.el`:
  - `chat-agent-start` takes a config plist (:model :messages :session
    :transport :on-event :should-stop-fn :steering-fn :followup-fn
    :max-steps :request-options) and returns a run state struct.
  - Single event channel: agent-start, turn-start, stream-chunk,
    tool-event, truncated, response, followup, steering, error,
    agent-end (status completed/stopped/error/cancelled).
  - Stop conditions and steering are callbacks, not hardcoded policy.
  - Truncation refusal (ported from pi): when finish_reason is
    "length", tool calls are parsed but refused BEFORE execution with
    a re-issue instruction as their synthetic result.
  - `chat-agent-cancel` owns handle cleanup for both transports
    (url buffer handles via chat-llm-cancel-request, stream processes
    via delete-process).
  - Streaming transport wraps the process sentinel to detect
    finished/exited/failed and feeds the assembled content into the
    same pipeline as sync responses.
- finish-reason plumbing: `chat-llm--extract-finish-reason` plus a
  `:finish-reason` key in `chat-llm--decode-response` results.
  Non-streaming only; streaming falls back to the stage-A parse-error
  feedback.
- `chat.el` loads chat-agent after the tool modules.
- 9 kernel tests with a stub transport (completion, tool loop,
  parse-error retry, max-steps, cancel, truncation refusal, steering,
  custom should-stop, followup contract) plus 1 finish-reason test.

## Lessons

- Refusal must happen before `chat-tool-caller-process-response-data`,
  because that function executes tools while processing. The first
  kernel draft executed truncated tool calls and a test caught it.
- Empty `choices` vectors are legal JSON and broke the first
  finish-reason extractor draft; guard vector length before `aref`.

## Verification

- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
  reports 453 results as expected, 0 unexpected.

## Not Done

- Phases 2-8 of the plan: chat-ui migration, chat-code migration,
  async shell tool, edit robustness and diff display, session JSONL,
  AGENTS.md ancestor stacking, UI rendering.
