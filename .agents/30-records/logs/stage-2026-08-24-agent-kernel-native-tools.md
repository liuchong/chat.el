# Stage Log 2026-08-24 Agent Kernel Native Tools

- Type: logs
- Attention: records
- Status: final
- Scope: project
- Tags: stage, agent, tools, plugin

## Summary

Extracted the agent kernel into `lisp/agent/`, aligned the loop with
native provider tool calling, and added an Emacs plugin host with
read-only live editor tools. Suite: 519 tests, 519 passing.

## What Landed

- Kernel files: `chat-agent-types.el`, `chat-agent-loop.el`,
  `chat-agent.el`, plus a `lisp/core/chat-agent.el` shim
- Loop contract: steering queue, native or JSON-in-text calls,
  truncated refusal, `:tool` transcript messages, follow-up queue
- LLM convertToLlm emits `tool_calls` / `tool` / `tool_call_id`;
  null content is a valid tool-only reply
- OpenAI-compatible streaming accumulates `tool_calls` deltas
- Plugin host plus `emacs` tools: buffers, read buffer, imenu, xref,
  project.el
- Code mode no longer duplicates tool results as system follow-up text

## Test Changes

- Agent tests expect `:tool` messages and cover native calls, follow-up
  queue, and plugin blocking
- LLM tests cover tool payloads, persisted result expansion, and null
  content
- Stream, provider-tools JSON shape, and plugin tests added

## Verification

- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
  reports 519 results as expected, 0 unexpected

## Not Done

- Anthropic streaming `tool_use` deltas are not accumulated
- User plugin directory loading stays opt-in
- File tools still run sequentially
