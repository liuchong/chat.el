# Current

- Type: progress
- Attention: entry
- Status: active
- Scope: project
- Tags: current, phase, kernel, plugin, sessions, work, mcp, subagents, capabilities

## Current Phase

Budget work is complete (2026-08-25), covering both meanings of the word.

The step budget lives in `lisp/agent/chat-agent-budget.el`:
`chat-agent-max-steps` is 300 and accepts `unlimited`, disclosure is
tiered so a run hears nothing while it has room, and the final step
withdraws tools so a ceiling produces a handoff rather than a death
mid-tool-call. Every mention of the budget also says running out is
survivable, because a run that reads a countdown as "answer now"
discards work it was close to finishing.

The context budget lives in `lisp/core/chat-context-budget.el`, with
per-category allowances in `chat-context-allocation`: shares of usable
context, a region (`fixed` or `compactable`), and an overflow policy per
category (`demote`, `compact`, `trim`, `warn`). Tool schemas are `warn`
only, since dropping a definition yields a failed provider call rather
than a context that fits. `lisp/core/chat-context-resident.el` lets an
instructions file declare spans that must never be summarized, using
HTML-comment markers that Markdown hides and other tools ignore.

The typed transcript model in `lisp/core/chat-transcript.el` stamps turn,
step, category and work on every message and projects the record down to
what a request may carry. **The displays do not render from it yet**, so
intermediate steps are still invisible on screen; that is the next stage.

Canonical suite: 727 tests passing.

The input command layer completed earlier the same day. Chat input parses
into commands through `lisp/core/chat-command.el`, covering shell
execution, history repeat, a session working directory, ephemeral
queries, and a literal escape. Command syntax accepts fullwidth
punctuation while arguments stay byte for byte.

Stage 15 capability-pack completion landed before it (2026-08-24).
Programming includes native completion and rendered web reading; office
includes Org agenda/capture/TODO/scheduling, Dired operations, and unit
conversion; daily work includes web reading and unsent message-mode
drafts. Profile overlays filter provider-visible schemas and all sensitive
actions use shared approvals.

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

- `lisp/core/chat-command.el`
- `lisp/core/chat-transcript.el`
- `lisp/core/chat-context-budget.el`
- `lisp/core/chat-context-resident.el`
- `lisp/agent/chat-agent-budget.el`
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
- `../20-reference/decisions/0007-context-budget-and-resident-context.md`
- `../20-reference/decisions/0006-typed-transcript-and-step-budget.md`
- `../20-reference/decisions/0005-typed-command-trust-and-punctuation-folding.md`
- `../20-reference/decisions/0004-agent-kernel-and-plugin-host.md`
- `../30-records/logs/stage-2026-08-25-context-budget-and-resident-context.md`
- `../30-records/logs/stage-2026-08-25-transcript-model-and-step-budget.md`
- `../30-records/logs/stage-2026-08-25-input-command-layer.md`
- `../30-records/logs/stage-2026-08-24-work-platform-stage8-final-verification.md`
- `../30-records/logs/stage-2026-08-24-work-platform-stage7-capability-packs.md`
- `../30-records/logs/stage-2026-08-24-work-platform-stage6-mcp-subagents.md`
- `../30-records/logs/stage-2026-08-24-work-platform-stage5-work-orchestration.md`
- `../30-records/logs/stage-2026-08-24-work-platform-stage4-session-runtime.md`
- `../30-records/logs/stage-2026-08-24-work-platform-stage3-plugin-runtime.md`
- `../30-records/logs/stage-2026-08-24-work-platform-stage2-kernel-parity.md`
- `../30-records/logs/stage-2026-08-24-agent-kernel-native-tools.md`
