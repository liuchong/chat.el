# Current

- Type: progress
- Attention: entry
- Status: active
- Scope: project
- Tags: current, phase, kernel, plugin, sessions, work, mcp, subagents, capabilities

## Current Phase

There is one chat surface (2026-08-26). Code capability is a property of
a session rather than a second display: `chat-code-mode` is gone, and a
coding session is a `chat-mode` buffer whose metadata carries a project
root, a focus file and a context strategy. 1712 lines left
`lisp/code/chat-code.el` and 475 arrived in `lisp/ui/chat-ui.el`, the
difference being the duplicated pipeline itself. Decision 0009 records
why the two surfaces could not be told apart by any principle, and why
the merge had to precede transcript rendering rather than follow it.

Two invariants are asserted rather than reviewed: the keymap and
`chat-commands-help` agree key by key in both directions, and every `M-x`
name in the docs is a real command.

Budget work completed the day before (2026-08-25), covering both meanings
of the word.

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
what a request may carry. The display renders from it: committed history
is redrawn from the session's messages, a live tail holds only what has
arrived and not been recorded, and `message-appended` hands one to the
other. That handoff is what keeps an intermediate step on screen instead
of being overwritten by the step after it. Reasoning and tool work fold
behind a summary row, interim prose is italic, the answer is ordinary text
and never folds. Decision 0010 records the shape.

Storage and self-knowledge landed on the same day. A run is told where its
own transcript is and can filter it back through `session_log`
(`lisp/core/chat-session-log.el`), grouped by turn so a question stays
with the steps that answered it. `lisp/core/chat-scratch.el` gives each
session a pruned scratch directory the file tools can reach.
`lisp/core/chat-knowledge.el` keeps a global Markdown note store whose
index rides in the prompt while its bodies stay on disk — a store that
grows with use cannot be injected whole without starving the working
space. The assembled block measures itself against the system prompt share
and shortens to paths alone when it does not fit, which is what an 8K
window requires.

Canonical suite: 828 tests passing.

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

- `chat.el` (sessions, the one keymap, help)
- `lisp/ui/chat-ui.el` (the one renderer and request pipeline)
- `lisp/code/chat-code.el` (code capability as session properties)
- `lisp/core/chat-command.el`
- `lisp/core/chat-i18n.el` (+ `chat-i18n-zh-cn.el`)
- `lisp/core/chat-transcript.el`
- `lisp/core/chat-context-budget.el`
- `lisp/core/chat-context-resident.el`
- `lisp/core/chat-session-log.el`
- `lisp/core/chat-scratch.el`
- `lisp/core/chat-knowledge.el`
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
- `../20-reference/decisions/0012-input-surface-and-language.md`
- `../20-reference/decisions/0011-auto-and-the-command-table.md`
- `../20-reference/decisions/0010-rendering-the-transcript.md`
- `../20-reference/decisions/0009-one-chat-surface.md`
- `../20-reference/decisions/0008-self-knowledge-and-shared-storage.md`
- `../20-reference/decisions/0007-context-budget-and-resident-context.md`
- `../20-reference/decisions/0006-typed-transcript-and-step-budget.md`
- `../20-reference/decisions/0005-typed-command-trust-and-punctuation-folding.md`
- `../20-reference/decisions/0004-agent-kernel-and-plugin-host.md`
- `../30-records/logs/stage-2026-08-26-input-surface-and-language.md`
- `../30-records/logs/stage-2026-08-26-auto-default-command.md`
- `../30-records/logs/stage-2026-08-26-transcript-rendering.md`
- `../30-records/logs/stage-2026-08-25-self-knowledge-and-shared-storage.md`
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
