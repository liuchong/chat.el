# Current

- Type: progress
- Attention: entry
- Status: active
- Scope: project
- Tags: current, phase, kernel, plugin, sessions, work, mcp, subagents, capabilities

## Current Phase

Stage 11 plugin runtime closure is complete (2026-08-24). Plugins now
roll back one reverse-chronological resource stack across tools, services,
and hooks, restoring replaced values and cleaning up even when teardown
fails. Persisted forged tools retain owner, sensitivity, effects, and
parameter enumerations. Canonical suite: 571 tests passing.

## Main Objective

Keep the agent loop as the only driver: `chat-message` throughout,
`chat-llm--format-messages` as the provider boundary, tool results as
ordered `:tool` messages, steering and follow-up queues, truncated
response refusal, per-step context transforms, typed events, and
project-scoped Emacs tools. Extend the host through `lisp/plugin/`
rather than growing the loop; plugin resources must have owner metadata
and roll back cleanly when stopped. Preserve session durability through
JSONL-compatible state entries and computed recovery metadata. Work
orchestration must stay declarative and cancellable; no untrusted Lisp
evaluation is allowed in workflow records. MCP and sub-agent lifecycle
must be visible as summarized state instead of dumping child transcripts
into parent context. Capability packs must use session overlays so each
surface advertises only relevant scoped tools.

## Active Modules

- `lisp/agent/chat-agent.el`
- `lisp/agent/chat-agent-loop.el`
- `lisp/agent/chat-agent-transcript.el`
- `lisp/agent/chat-agent-types.el`
- `lisp/plugin/chat-plugin.el`
- `lisp/plugin/chat-plugin-emacs.el`
- `lisp/llm/chat-llm.el`
- `lisp/tools/chat-tool-caller.el`
- `lisp/tools/chat-work.el`
- `lisp/tools/chat-mcp.el`
- `lisp/tools/chat-subagent.el`
- `lisp/tools/chat-capability-packs.el`
- `lisp/core/chat-session.el`
- `lisp/core/chat-session-tree.el`
- `lisp/core/chat-agent.el` (load-path shim)
- `tests/unit/test-chat-agent.el`
- `tests/unit/test-chat-plugin.el`

## Recommended Reads

- `../10-active/focus.md`
- `../20-reference/knowledge/agent-kernel-contract.md`
- `../20-reference/decisions/0004-agent-kernel-and-plugin-host.md`
- `../30-records/logs/stage-2026-08-24-work-platform-stage8-final-verification.md`
- `../30-records/logs/stage-2026-08-24-work-platform-stage7-capability-packs.md`
- `../30-records/logs/stage-2026-08-24-work-platform-stage6-mcp-subagents.md`
- `../30-records/logs/stage-2026-08-24-work-platform-stage5-work-orchestration.md`
- `../30-records/logs/stage-2026-08-24-work-platform-stage4-session-runtime.md`
- `../30-records/logs/stage-2026-08-24-work-platform-stage3-plugin-runtime.md`
- `../30-records/logs/stage-2026-08-24-work-platform-stage2-kernel-parity.md`
- `../30-records/logs/stage-2026-08-24-agent-kernel-native-tools.md`
