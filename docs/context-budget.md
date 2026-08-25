# Context Budget

A context window is not one pool. It is spent by sources that grow for
unrelated reasons -- a tool set that got richer, an instructions file that
got longer, a conversation that ran on -- and any one of them can starve the
rest. This is how the window is divided, what happens when a share is
exceeded, and what that works out to on real models.

## Two budgets

| | Step budget | Context budget |
|---|---|---|
| Set by | this client | the provider |
| Exceeding it | an orderly stop | a rejected request |
| Remedy | wrap up and continue in a new round | summarize history |
| Configured by | `chat-agent-max-steps` | the model's window |

See the README for the step budget. This document covers the second.

## What the model is told

The system prompt carries the *policy*, which never changes: history is
summarized rather than deleted, standing instructions are never
summarized, and the run should record conclusions rather than quote at
length.

The *numbers* appear only once usage passes
`chat-context-compact-at-ratio` (75%). A figure written into the system
prompt is wrong by the time it is read, and a count repeated while there is
ample room teaches the run to ignore it.

The tight reminder asks for conclusions to be stated now, because a summary
preserves what was written down and not what was merely looked at.
Reporting scarcity on its own produces hoarding.

## Overflow policy

The categories are worth separating not because of their sizes but because
of what can be done when one overflows.

| Policy | Behaviour | Used for |
|---|---|---|
| `demote` | Honour what fits, move the excess to compactable | Declared resident text, in document order |
| `compact` | Summarize | History and project notes, where a condensed record still helps |
| `trim` | Drop outright | Content that can be fetched again, such as file excerpts |
| `warn` | Report, change nothing | Tool schemas |

`warn` is the important one. Dropping a tool definition does not produce a
context that fits; it produces a call that fails at the provider, with no
trace of why. So an oversized tool set is reported and left alone, and the
remedy belongs to whoever enabled the tools.

## Allocation

Shares are fractions of *usable* context, which is the window minus
`chat-context-reply-reserve-ratio` (15%) held back for the reply, since the
window covers request and response together.

| Category | Region | Overflow | Share |
|---|---|---|---|
| System prompt | fixed | warn | 4% |
| Resident rules | fixed | demote | 10% |
| Tool definitions | fixed | warn | 12% |
| Capability packs | fixed | warn | 4% |
| MCP and dynamic tools | fixed | warn | 3% |
| Subagent definitions | fixed | warn | 1% |
| Long term memory | fixed | trim | 1% |
| Project instructions | compactable | compact | 5% |
| File context | compactable | trim | 20% |
| Conversation | compactable | compact | 40% |

The fixed shares total 35%, which is exactly
`chat-context-protected-max-ratio`; compactable totals 65%. A test asserts
both, so an edit to the table cannot quietly promise the same tokens twice.

## What that is in tokens

Usable context, then the per-category allowance:

| Category | 8K | 32K | 128K | 200K | 262K | 1M |
|---|---|---|---|---|---|---|
| *Usable* | *7.0K* | *27.9K* | *111.4K* | *170.0K* | *222.8K* | *891.3K* |
| System prompt | 278 | 1.1K | 4.5K | 6.8K | 8.9K | 35.7K |
| Resident rules | 696 | 2.8K | 11.1K | 17.0K | 22.3K | 89.1K |
| Tool definitions | 835 | 3.3K | 13.4K | 20.4K | 26.7K | 107.0K |
| Capability packs | 278 | 1.1K | 4.5K | 6.8K | 8.9K | 35.7K |
| MCP and dynamic tools | 208 | 835 | 3.3K | 5.1K | 6.7K | 26.7K |
| Subagent definitions | 69 | 278 | 1.1K | 1.7K | 2.2K | 8.9K |
| Long term memory | 69 | 278 | 1.1K | 1.7K | 2.2K | 8.9K |
| Project instructions | 348 | 1.4K | 5.6K | 8.5K | 11.1K | 44.6K |
| File context | 1.4K | 5.6K | 22.3K | 34.0K | 44.6K | 178.3K |
| Conversation | 2.8K | 11.1K | 44.6K | 68.0K | 89.1K | 356.5K |

## The part that does not scale

Shares scale with the window. The cost of a tool set does not: a schema
costs what it costs on every model. So a rich tool set does not fit a small
window's share of it, and no ratio can fix that.

`chat-context-allocation-minimum-window` answers the question this actually
raises -- not whether a tool set is too big, but which models it fits on:

| Content | Category share | Smallest window that holds it |
|---|---|---|
| 31.5K of tool schemas | 12% | 309K |
| 11.9K of capability packs | 4% | 350K |
| 6.6K of rules, declared resident | 10% | 78K |

The practical reading: a full tool set plus capability packs plus MCP is a
large-window configuration. On a 128K model, 13.4K is the whole tool
allowance, so tool groups have to be selected rather than all enabled. The
panel says so explicitly, naming the window that would fit.

## Inspecting a session

`M-x chat-context-budget-panel` shows the table for the current session's
model with measured values beside the allowances, and prints the overflow
warnings underneath:

```
Context window: 262144 tokens, 222822 usable after the 15% reply reserve
In play: 41003 tokens (18%), 181819 left

Category                 Region       Overflow  Share    Allowed   Measured
--------------------------------------------------------------------------
Tool definitions         fixed        warn        12%      26738      31500
...
Tool definitions uses 31500 tokens, over its 26738 token share. Nothing is
dropped, because a missing definition fails at the provider instead of
fitting. Disable what is not needed, or move to a window of at least 308824
tokens.
```

Measurements cover the sources that can be counted directly: tool schemas
by encoded size, memory, the two halves of the project instructions, and
the conversation. A source that cannot be counted honestly is shown as `-`
rather than estimated, because a number nobody can trace is worse than an
admitted gap.

`M-x chat-context-budget-report` gives the one-line version in the echo
area.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `chat-context-allocation` | see above | Per-category share, region and overflow policy |
| `chat-context-default-window` | 131072 | Window assumed when a provider declares none |
| `chat-context-reply-reserve-ratio` | 0.15 | Share held back for the reply |
| `chat-context-protected-max-ratio` | 0.35 | Ceiling on the whole fixed region |
| `chat-context-compact-at-ratio` | 0.75 | Usage that triggers compaction and the reminder |
| `chat-context-resident-headings` | see docs | Heading names that imply residency |

`chat-context-default-window` is deliberately not optimistic: overshooting
gets a request rejected, while undershooting only compacts earlier than
necessary.

See [resident-context.md](resident-context.md) for declaring which
instructions must never be summarized.
