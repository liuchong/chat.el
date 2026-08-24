# Current

- Type: progress
- Attention: entry
- Status: active
- Scope: project
- Tags: current, phase, kernel, plugin, sessions

## Current Phase

Stage 4 durable session runtime work is complete (2026-08-24). The loop
lives in `lisp/agent/`, emits ordered assistant/tool transcript
messages, rebuilds context per step, supports next-turn prepare hooks,
and uses session metadata for branch/tree browsing, compaction records,
append-boundary recovery, and interrupted tool-run detection.

## Main Objective

Keep the agent loop as the only driver: `chat-message` throughout,
`chat-llm--format-messages` as the provider boundary, tool results as
ordered `:tool` messages, steering and follow-up queues, truncated
response refusal, per-step context transforms, typed events, and
project-scoped Emacs tools. Extend the host through `lisp/plugin/`
rather than growing the loop; plugin resources must have owner metadata
and roll back cleanly when stopped. Preserve session durability through
JSONL-compatible state entries and computed recovery metadata.

## Active Modules

- `lisp/agent/chat-agent.el`
- `lisp/agent/chat-agent-loop.el`
- `lisp/agent/chat-agent-transcript.el`
- `lisp/agent/chat-agent-types.el`
- `lisp/plugin/chat-plugin.el`
- `lisp/plugin/chat-plugin-emacs.el`
- `lisp/llm/chat-llm.el`
- `lisp/tools/chat-tool-caller.el`
- `lisp/core/chat-session.el`
- `lisp/core/chat-session-tree.el`
- `lisp/core/chat-agent.el` (load-path shim)
- `tests/unit/test-chat-agent.el`
- `tests/unit/test-chat-plugin.el`

## Recommended Reads

- `../10-active/focus.md`
- `../20-reference/knowledge/agent-kernel-contract.md`
- `../20-reference/decisions/0004-agent-kernel-and-plugin-host.md`
- `../30-records/logs/stage-2026-08-24-work-platform-stage4-session-runtime.md`
- `../30-records/logs/stage-2026-08-24-work-platform-stage3-plugin-runtime.md`
- `../30-records/logs/stage-2026-08-24-work-platform-stage2-kernel-parity.md`
- `../30-records/logs/stage-2026-08-24-agent-kernel-native-tools.md`
