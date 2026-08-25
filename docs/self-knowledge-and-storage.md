# Self-knowledge and storage

A run has three places it can reach outside its own context, and the
distinction between them is the part worth internalizing:

| Place | Lifetime | Written by | Purpose |
| --- | --- | --- | --- |
| Session transcript | Permanent, per session | The system | What already happened, in full |
| Scratch space | Days, per session | The model | Somewhere to put things down |
| Shared knowledge | Permanent, global | The model | What should outlive the session |

All three are named in the system prompt. A capability the model is not
told about does not exist as far as a run is concerned.

## The session transcript

Every session is a JSONL file under `chat-session-directory`, one entry
per line, named for the session id. It holds the complete record —
including turns that were summarized out of the context and intermediate
work that was never sent to the model at all.

This matters because the context a run sees is not the conversation. It
is a compacted view of it. Without knowing the full record exists, a run
that has lost the early part of a conversation will ask again or guess.

### What an entry carries

```json
{
  "role": "assistant",
  "content": "...",
  "timestamp": "2026-08-25T22:14:03",
  "toolCalls": [...],
  "toolResults": [...],
  "metadata": {"turn": 3, "step": 2, "category": "ai-progress", "work": "tool-call"}
}
```

The `metadata` stamps are what make the file searchable, and they are
written by the transcript model rather than added for this purpose. See
[the transcript model decision](../.agents/20-reference/decisions/0006-typed-transcript-and-step-budget.md).

### Reading it back

The `session_log` tool filters the file. Filters compose:

| Filter | Selects |
| --- | --- |
| `turn` | One exchange |
| `category` | `user`, `ai-progress`, `ai-final`, `command-reply`, `shell-output`, `system-detail` |
| `work` | `thinking`, `tool-call`, `tool-result`, `message` |
| `role` | `user`, `assistant`, `tool`, `system` |
| `since` / `until` | A time range |
| `text` | A literal content match |
| `limit` | How much comes back, defaulting to `chat-session-log-default-limit` |

Results are grouped by turn, not ordered by time. A question, the steps
that answered it and the final answer are one unit of meaning; a
time-ordered list interleaves them with everything else that happened,
which is what makes a raw transcript unreadable. A run asking "what did I
conclude about X" wants the turn.

Entry content is excerpted at `chat-session-log-content-max-chars`. A
lookup exists to spend less context than carrying everything, so it needs
a ceiling of its own — a tool result can be enormous.

## Scratch space

`chat-scratch-directory` holds one directory per session. It is writable
by the file tools, which is why the scratch root is in
`chat-files-allowed-directories`: describing a writable path in the
prompt while the tools refuse it produces a run that keeps retrying and
cannot explain why it fails.

Per session rather than shared, for two reasons. Two runs both writing
the obvious file name do not collide, and a session's leftovers can be
identified and removed as a unit.

It is scratch space and it is deleted. `chat-scratch-max-age-days`
defaults to 7; pruning happens when a session opens, which is when the
answer is cheap to compute and nothing is mid-write. The session being
opened is always spared, so a long-running session cannot lose the
directory it is working in. Set the variable to nil to keep everything,
accepting that the directory then only grows.

Writing something down and re-reading the part that matters costs far
less context than carrying it through every request, so the prompt says
so explicitly.

## Shared knowledge

`chat-knowledge-directory` holds Markdown notes that persist across every
session and project. This is what makes the tool better the more it is
used: a constraint discovered the hard way, a technique that generalizes,
an approach that failed and why.

### General knowledge only

The store is global, and that cuts both ways. A note is visible in every
future session, including work for entirely unrelated parties, so it must
be knowledge that stays true away from the work that produced it.

The prompt asks for the technique rather than the case. "A tool's
parameters arrive positionally, so an implementation reading a keyword
list mis-binds silently" belongs here. "Service X on host Y needs flag Z"
does not — it is useless elsewhere and it carries information out of the
project it came from. Project and repository names, paths, hostnames,
internal identifiers and credentials are out.

The bar is deliberately high, and the prompt says to prefer writing
nothing: a small store of durable observations is worth more than a large
one that has to be distrusted. Start conservative and see whether the
notes that do get written turn out to be worth reading.

Policy is a prompt-level control, since what counts as project-specific
needs judgement. Two classes do not, and are refused mechanically by
`chat-knowledge-reject-patterns` and a home-directory path check:
credential-looking material, and absolute paths that name one machine.
The tilde form stays allowed — `~/.chat/` is generic, and refusing it
would block notes about the tool's own configuration, which are exactly
the reusable kind.

### Not the long term memory file

`chat-memory-file` is curated by the user and states what the assistant
should do. Knowledge notes are written by the model and record what it
found out. Keeping them apart matters because the trust differs: a user
instruction is authoritative, and a note a run wrote about its own
findings is evidence that may be stale or wrong. The prompt says so, and
invites correction rather than accumulation.

### Why the prompt carries an index

The store grows with use, and anything injected into every request must
not. So the prompt lists note names and titles; bodies are read on demand
with `knowledge_read`.

Injecting the whole store would put a monotonically growing block into
the fixed region of the context and slowly starve the working space —
exactly the failure [the context budget](context-budget.md) exists to
prevent. An index costs about a line per note and stays useful at a
hundred of them. It is capped at `chat-knowledge-index-max-entries`
anyway, listing the most recently changed notes past that point.

A note's first line is its title, which is what the index shows. That
keeps the format its own metadata and the store editable by hand.

### Tools

| Tool | Does |
| --- | --- |
| `knowledge_read` | Open one note by name |
| `knowledge_write` | Create or, with `mode: "append"`, extend one |
| `knowledge_search` | Find notes mentioning some text |

Append exists because a note earns its value by being corrected and
extended. A run that can only replace will either clobber what it did not
write or start a near-duplicate note.

Note names come from the model, so they are reduced to a safe file base
rather than sanitized around: a name that cannot produce a path inside
the store produces no path at all.

## Fitting the prompt share

The full storage block runs to a few hundred tokens. Against a 128K
window that is a tenth of the system prompt share and not worth
discussing. Against an 8K window it is larger than the entire share.

So the block is measured against the share it actually lands in and
shortened when it does not fit, rather than tuned per window:

| Window | System prompt share | Block | Form |
| --- | --- | --- | --- |
| 8K | 278 | 88 | Short |
| 32K | 1,114 | 627 | Full |
| 128K | 4,456 | 627 | Full |

The short form keeps the paths and tool names and drops the reasoning.
That is the right thing to lose: explaining at length why a run should
consult its transcript is worthless if doing so crowds out the
conversation it was meant to recover, and a block trimmed down to advice
is worse than no block — the run still pays for it and still cannot find
the file.

## Inspecting it

- `M-x chat-context-budget-panel` — where these blocks land in the budget
- `M-x chat-knowledge-open` — the shared notes as a directory
- `M-x chat-edit-memory` — the user-curated memory file, which is separate
