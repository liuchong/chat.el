# Stage — Self-knowledge and shared storage

- Type: record
- Attention: reference
- Status: complete
- Scope: stage
- Date: 2026-08-25
- Tags: session-log, scratch, knowledge, prompt, context-budget

## What Landed

Three storage places a run can reach outside its own context, all named in
the system prompt.

`lisp/core/chat-session-log.el` — the transcript a run can read back. The
prompt block names the session id, its name, the model, and the path of
the JSONL file, and states that the file holds turns the context no longer
does. The `session_log` tool filters on the stamps the typed transcript
already writes — turn, step, category, work — plus role, a time range and
literal text, and groups results by turn.

`lisp/core/chat-scratch.el` — one scratch directory per session under
`chat-scratch-directory`, created when a session opens so the path named
in the prompt exists by the time the model is told about it. Pruned after
`chat-scratch-max-age-days` (7), sparing the session being opened. The
scratch root joins `chat-files-allowed-directories`.

`lisp/core/chat-knowledge.el` — a global Markdown note store. Read, write,
append and search tools; a note's first line is its title. The prompt
carries the index only, capped at `chat-knowledge-index-max-entries`.

Wiring: `chat-tool-caller-build-system-prompt` takes the session and emits
the three blocks together. `chat.el` requires the modules, registers the
four tools, and creates and prunes scratch space on session open.

## Why It Is Shaped This Way

The transcript needed no new writing. 0006 already stamped every message
with turn, step, category and work, and sessions were already JSONL, so
the record was filterable and nobody had been told. Grouping by turn
rather than time is the part that makes it readable: a question, its steps
and its answer are one unit, and ordering by timestamp interleaves them
with everything else that happened.

Scratch space is per session so that two runs writing the obvious file
name do not collide and so leftovers are attributable. It is deleted
because a directory that only grows is the same problem as a context that
only grows, and because calling something temporary while keeping it
forever is a lie the model will act on.

The knowledge store puts an index in the prompt and leaves bodies on disk.
This is the decision the rest hangs on: the store grows with use, and a
growing block in the fixed region would slowly starve the working space —
exactly what 0007 was built to prevent. Notes are also kept separate from
the user's memory file, because a user instruction is authoritative and a
note a run wrote about its own findings is evidence that may be stale.

## What Measurement Changed

The full storage block is 433 tokens. The system prompt share of an 8K
window is 278. So on a small window the block explaining how to recover a
lost conversation would have crowded out the conversation.

The fix is not per-window tuning but self-measurement: assemble the full
block, compare it to `chat-context-allocation-tokens` for its category,
and fall back to a short form when it does not fit. The short form keeps
paths and tool names, since a block trimmed to advice is worse than absent
— the run still pays for it and still cannot find the file. Verified at
88 tokens on 8K and 433 on 128K.

## Verification

- 773 tests pass (was 727); 46 added across the three modules
- Storage block rendered and measured at 8K and 128K against its share
- Filters, turn grouping, excerpt truncation, scratch pruning with the
  open session spared, name-traversal rejection, append versus replace,
  and the index cap all covered
- Two prompt-builder stubs in existing tests updated for the new argument

## Follow-ups Recorded

Only `kimi-code` declares a real `:context-window`. Every other provider
falls back to 131072, and now that every allowance derives from that
number, a wrong window mis-sizes the entire budget silently. Noted in
`.agents/10-active/focus.md`.

## Still Open

Rendering from `chat-transcript-plan` remains the next stage. Intermediate
steps are stored, stamped and now readable back through `session_log`, but
neither display draws them, so they are still invisible on screen.
