# Current

- Type: progress
- Attention: entry
- Status: active
- Scope: project
- Tags: current, phase, migration

## Current Phase

Agent kernel phase 1 is complete (2026-08-07).

## Main Objective

Execute the approved plan "unified event-driven kernel" (pi agent-loop
port): replace the duplicated chat-ui/chat-code request and tool loops
with the new `lisp/core/chat-agent.el` kernel, then land the borrowed
designs from pi, kimi-cli, and opencode: async shell execution with
timeout and output spill, edit replacer cascade with unified diff
display, append-only JSONL sessions, AGENTS.md ancestor stacking, and
differential UI rendering.

## Active Modules

- `AGENTS.md`
- `.agents/`
- `lisp/core/chat-agent.el`
- `lisp/ui/chat-ui.el`
- `lisp/code/chat-code.el`
- `lisp/`
- `tests/`
- `docs/troubleshooting-pitfalls.md`

## Recommended Reads

- `../10-active/focus.md`
- `../10-active/risks.md`
- `../30-records/logs/conversation-2026-08-07-deep-project-review.md`
- `../30-records/logs/stage-2026-08-07-functional-fix-pack.md`
- `../30-records/logs/stage-2026-08-07-agent-kernel-phase1.md`
- `../20-reference/decisions/0001-agent-knowledge-layout.md`
- `../20-reference/decisions/0002-json-structured-protocols.md`
