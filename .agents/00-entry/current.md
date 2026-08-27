# Current

- Type: progress
- Attention: entry
- Status: active
- Scope: project
- Tags: current, phase, runtime, bridge, termini

## Current Phase

M0 through M8 of the Agent Runtime roadmap are complete (2026-08-28). Decision
0019 fixes the foundational contracts and Spec 014 orders their delivery through
M8 so later features depend on runtime boundaries rather than provider, UI or
process internals.

`lisp/core/chat-event.el` is the first contract. It separates synchronous
blockers from post-persistence observers, records handler outcomes in the
existing session wire, keeps live subjects out of persistence and prevents
producer context from forging runtime-owned audit fields. Session, turn,
prompt, tool, permission, background task, child-agent and compaction paths
emit through it. Security boundary failures close; notification failures stay
auditable and continue.

Decision 0020 and the M2 implementation make model behavior explicit. Static,
discovered and user capability facts resolve by provenance without model-name
guessing, and `unknown` remains distinct from false. Streaming and asynchronous
requests now emit one ordered model event vocabulary for text, reasoning, tool
deltas, usage and terminal outcomes. Application callers use that runtime or a
compatibility projection over it; reasoning required for a tool continuation is
replayed only for an explicitly capable model.

Decision 0021 adds the M3 extension contracts. Named hooks wrap the unified M1
event bus, declarative skill and profile manifests load lazily behind an
explicit project trust boundary, and custom agents resolve through the same
runtime loop. Tool authority can only narrow, approval can only tighten and
known model conflicts fail before dispatch. The selected profile remains
session state while each run records a bounded resolved snapshot without
rewriting earlier messages.

Decisions 0022 through 0024 complete unified tasks, typed content and recovery.
Foreground runs, background commands, workflows and subagents share durable
task identity; content remains typed through transport; checkpoints and owned
workspaces reconstruct intent without resurrecting stale processes.

Decision 0025 and M7 add attributable scoped memory, Trace reconstruction over
all session-wire archives and immutable deterministic evaluations. Memory
retrieval is provenance-aware and excludes sensitive, expired, archived and
out-of-scope items. Trace exports measurements and identifiers without copying
transcripts. Five offline scenarios cover editing, Guard, recovery, compaction
and normalized provider events. Native views expose Memory review, Trace detail
and evaluation run, export and comparison commands.

Decision 0026 and M8 add the optional `termini.el` control surface over the
versioned App Server protocol. The bridge negotiates capabilities, correlates
JSON-RPC responses, never replays mutations after reconnect and projects
RuntimeSessions, messages, jobs, tails and attachments without persisting a
second remote state store. Native session and job views read only through the
bridge. Loading `chat.el` alone neither loads the integration nor starts a
sidecar.

The canonical offline suite passes 1539/1539. A separate foreground live smoke
negotiated protocol `2026-07-08`, read RuntimeSessions, shut down cleanly and
left no App Server process behind.

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

The commands were given names that mean what they say. `/send` is the
recorded multi-step conversation -- the main behaviour of the surface,
which had no name until now -- and `/quick` is the ephemeral aside it was
being confused with. `/?` and `/!` are aliases through one
mechanism, so `chat-ui--command-table` holds one entry per command;
`/ask` and `/question` are deleted, because both read equally well as
either way of asking and a name that must be memorized to be told apart
from its neighbour earns nothing. Auto returns to `/send` rather than to a cleared variable:
commands declare `:default sticky` or `reset`, anything that asks the
model releases the claim, and the holder shows in the input prompt as
`cmd> `. `/queue`, `/flush` and `/drop` collect notes and send them as one
numbered message. Decision 0013 records it.

Language covers the surface rather than only the help. Command names have
aliases, so `/auto` and `/自动` resolve to one entry and any language's
names are accepted while completion offers the language in use. Role
labels, fold rows, the status line and every message go through
`chat-i18n`. What the model is told has its own two switches:
`chat-reply-language` for the language of the answer, which is the
reliable lever, and `chat-prompt-language` for the language of the
instructions, which is separate because translated guidance changes
behaviour in ways that cannot be measured from here. JSON keys, tool
names, patch envelopes and fence languages are never translated at either
setting, since a parser matches them literally.

Canonical suite: 1511 tests passing.

The prompt says which provider it will reach, not just which command
holds the line (spec 007). An unclaimed line carries the provider's mark
and the model the request will actually name; a shell line carries a
shell mark and no model, because RET there reaches no model. The tables
are pure functions in `lisp/ui/chat-mark.el`: single-column BMP
characters rather than emoji or an icon font, since only a face can
follow the background from light to dark and only one column keeps a
monospaced buffer in step, and a glyph the frame cannot draw is dropped
so the prompt degrades to exactly what it was before. Brand colours are
used for brands only, asserted by a static test over the tree. Clicking
the model opens the menu and switches through `chat-set-model`, which
already refuses mid-response and already persists; the affordance appears
only when there is more than one model to pick, and a terminal without
popup menus gets `completing-read`.

Which model is a session-level choice, not a registry snapshot (spec
008). A provider symbol used to answer three questions at once -- which
vendor, over which protocol, running which model -- so a vendor speaking
two protocols read as two companies and the models each one serves were
invisible. Registrations now carry `:vendor` (defaulting to themselves),
`:protocol` (injected by whichever compatibility factory registered them)
and `:models` (defaulting to the one default model), and the session
carries a `model-name` that is nil when it means "the provider's default
at request time" -- writing that default in would freeze a snapshot of a
changeable setting, which is the bug being removed. The menu groups by
vendor, one item per model, current one marked; the protocol is not
offered, since "I want k3" is the request and the wire format is not, and
the other protocol stays reachable by name because it is a different code
path. `chat-llm-provider-models` is the single question "what does this
serve": both real vendors answer `GET /models` with exactly the written
list, so replacing the list with discovery is one function, not every
menu. Provider and model also moved into the JSONL state entry, since the
append path does not rewrite the header and a mid-session switch could be
saved and lost.

The command prompt behaves like a shell in the two places it did not. A
subprocess cannot move its parent's working directory or set its parent's
environment, which is the whole reason any of this has to be interpreted
in Lisp, and that boundary now has a file: `lisp/ui/chat-shell-builtins.el`
owns `cd`, `pushd`, `popd`, `dirs`, `export` and `unset`, and nothing
else, because the shell is better at everything else than we would be.
`cd -` used to reach `expand-file-name`, which read the dash as a relative
path named `-` and reported it missing; the previous directory is now
recorded before each move. An `export` reaches the next command instead of
only the subshell that ran it.

Auto path completion is off. A completion UI that is open takes RET for
itself, so the key that sends a message became the key that picks a
candidate and the message needed a second RET, and the popup moved the
buffer under someone still typing. TAB still completes, filling the common
prefix on the first press and listing on the second, as a shell does.

Output format is now stated rather than assumed. Every model writes
Markdown by habit and the renderer was built around that habit, so the
system prompt asks for it and narrows it to the subset a buffer displays
well -- ATX headings from level two, no hand-wrapped paragraphs, a
language on every fence, shallow lists, narrow tables, no HTML or math.
Each restriction carries its reason, because a prompt rule without one
reads as optional.

Specs 005 and 006 record where this goes next, with two divisions stated
outright. Markdown the format owns full-document input and output and is
the source of truth; `lisp/core/chat-markdown.el` owns only its display,
gets an Org-like result out of Markdown syntax without an external
renderer, and never lets a rendering flow back as data. And MDP is a data
transport protocol with JSON's standing rather than a document tool, so
`chat-mdp.el` is a codec first — MDP text to and from an Elisp
representation — with its display role bounded by a two-views rule: the
document view belongs to 005 and comes free because an MDP payload is
valid Markdown, while the machine view belongs to the codec because 005
has no parse result and cannot tell structure from comment. Both modules
sit in core on the precedent of `chat-transcript.el`, which keeps the
repository's strict ui → core direction intact and lets them share one
implementation of width-aware column layout. MDP is adopted for tool calls
and tool results and declined for multi-line payloads, whose single-line
values need the same escaping JSON does while the existing patch envelope
needs none. MDS is deferred at zero cost, since its own specification
makes validation a layer separable from parsing.

A run is now something you can watch happen. It used to be that a
reasoning model thought for a minute with the screen perfectly still and
then painted its whole reply at once, and the log proves the transport was
never at fault -- bytes arrived continuously for the whole minute. The UI
event handler was a six-branch `cond` with no final clause, and
`stream-reasoning` was one of eleven event types that fell off the end and
were discarded without a word. Reasoning now renders as it arrives, dim
and folded away once the answer starts; the handler has a catch-all; and a
test reads both source files and fails if the agent gains an event the UI
neither handles nor names. Streaming is on by default, and the flag is
declared once rather than as a `defvar` that silently beat the `defcustom`
below it.

Waiting is now legible. Twenty seconds passed between starting curl and
the first token on a 308KB prompt, and nothing on screen said so. Reasoning
counts as arriving data in the trace, the live line names the phase it is
in, and the seconds tick while the first token is outstanding -- a number
that moves is the difference between a reader who waits and one who
assumes a hang. A stall after reasoning says reasoning stalled instead of
claiming nothing ever came.

The typed transcript record finally has a writer. Turn, step, category,
work and reasoning existed with fold styles and faces keyed to them, and
grep found the stamping API called only from tests, so a multi-round run
reached disk as a flat list the display had to guess at. Messages are
stamped where they are made, the turn number is settled once per run so
steering cannot push later steps into the next turn, and reasoning rides
on the step that produced it rather than becoming a message a later
request would send back. A session can also name its own history file.

`M-p` and `M-n` recall what was sent, persisted across restarts. The stub
that printed "History navigation not yet implemented" is gone.

The wiki became a feature. `lisp/wiki/chat-wiki.el` had been in the tree
four months with five documented `/wiki-*` names, no handler behind any of
them and no tests; it is now one `/wiki` with subcommands, reached by the
model through `wiki_search`, `wiki_read` and `wiki_write` rather than
through a prompt index, because a wiki grows without bound and that growth
does not belong in the fixed region of the context. Unreachable turned out
not to mean inert: a top-level form wrote to disk whenever a `wiki`
directory sat beside `default-directory`, which in the test runner is this
repository. Ten defects came out with it, most of them silent —
frontmatter matched with `.` never parsed across lines, so every title and
date fell back to a filename; CJK titles were slugified by deleting
non-ASCII, which collided them all on the empty string; and the wikilink
pattern used `[^\]]`, where a backslash is not an escape inside a
character alternative, so link extraction always returned nothing and
backlinks, orphans and broken links had never worked at all. The last four
were found not by tests but by running the thing end to end in Chinese,
which is worth remembering: the 42 tests written first all passed, because
the test helper hand-wrote the frontmatter that the ordinary path failed to
write. Decision 0015 records it.

Approval has an approver (spec 013). The middle mode was named for
something it did not do: `auto` ran the fast path for grants, then a fixed
rule list, then refused without asking -- `manual` with the question
suppressed, which loses the user's ability to say yes and gains nothing,
since the list is the same list. It is now `guarded`, `auto` is an alias in
every reading path, and under it a model rules on the call.
`lisp/core/chat-approval-guard.el` sends one neutral request per call that
reaches the mode branch, against its own two-part prompt -- an immutable
preamble and policy rules the user may extend -- carrying facts and no
narrative: environment, arguments labelled untrusted, relative paths shown
as written and as resolved, and the gate's own objection as evidence. No
history, no task text, nothing from the executing model. An allow needs
`decision: allow`, `confidence: high` and a non-empty `matched-rule`; prose,
bad JSON, an abstain, a hedge, a timeout and a missing provider all refuse.

A verdict is worth what a person's approval is worth, which is one `memq`
in `chat-approval-command-consent-p` and is the whole mechanism -- the
gate's objection was handed to the guard, so a gate that refuses regardless
makes the verdict decoration. That price is bounded by a floor:
`chat-approval-guard-never-allow-p` refuses writes outside the boundary,
deleting a home or project root, rewriting published history, a credential
and the network in one command, and edits to the approval records
themselves, before any request is made and with no verdict able to move it.
A refusal returns as a tool result rather than an error, saying the policy
refused rather than the user, so the run picks another route instead of
looping -- the eight-minute git incident, one layer up. Authorization also
collapsed to one point: it used to happen separately in the two execution
paths, so a grant applied or did not depending on whether a tool declared
an `async-function`. Shadow running exists and ships off: the guard runs
alongside any mode, decides nothing, and records paired samples. Decision
0016 records it.

Two fixes landed before that. Tool call ids are now answered by one
function, so the assistant `tool_calls` entry and the `tool_call_id` of its
result cannot disagree; two fallbacks that did disagree made any session
with an id-less turn unsendable. And the session loader no longer wraps
`parse-time-string` in `decode-time`, which had been dating every reopened
message to 1970 and writing it back. Dates already on disk are lost.
Decision 0014 records the third: fullwidth normalization is a Unicode
range rather than a punctuation table, and its boundary is ownership --
chat.el folds what it interprets and leaves what it forwards, so `！` folds
and the `ls` after it does not.

The input command layer completed earlier. Chat input parses into commands
through `lisp/core/chat-command.el`, covering shell execution, history
repeat, a session working directory, ephemeral queries, and a literal
escape. Command syntax accepts fullwidth characters while arguments stay
byte for byte, and a command name may be non-ASCII, which is what lets a
translated name reach the same handler.

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
- `lisp/core/chat-approval.el`
- `lisp/core/chat-approval-guard.el`
- `lisp/core/chat-command-gate.el`
- `lisp/core/chat-session.el`
- `lisp/core/chat-session-tree.el`
- `lisp/core/chat-agent.el` (load-path shim)
- `tests/unit/test-chat-agent.el`
- `tests/unit/test-chat-plugin.el`

## Recommended Reads

- `../10-active/focus.md`
- `../20-reference/knowledge/agent-kernel-contract.md`
- `../20-reference/decisions/0013-naming-the-commands.md`
- `../20-reference/decisions/0012-input-surface-and-language.md`
- `../20-reference/decisions/0011-auto-and-the-command-table.md`
- `../20-reference/decisions/0016-a-model-that-approves.md`
- `../20-reference/decisions/0015-one-wiki-command.md`
- `../20-reference/decisions/0014-whose-command-is-it.md`
- `../20-reference/decisions/0010-rendering-the-transcript.md`
- `../20-reference/decisions/0009-one-chat-surface.md`
- `../20-reference/decisions/0008-self-knowledge-and-shared-storage.md`
- `../20-reference/decisions/0007-context-budget-and-resident-context.md`
- `../20-reference/decisions/0006-typed-transcript-and-step-budget.md`
- `../20-reference/decisions/0005-typed-command-trust-and-punctuation-folding.md`
- `../20-reference/decisions/0004-agent-kernel-and-plugin-host.md`
- `../30-records/logs/stage-2026-08-27-the-approver-and-its-floor.md`
- `../30-records/logs/stage-2026-08-26-commands-and-language.md`
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
