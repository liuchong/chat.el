# Structured Message Staging

- Type: record
- Attention: reference
- Status: complete
- Scope: input-workflow
- Tags: staging, session, checkpoint, attachments, provenance

## Result

Message staging is now a strict schema-versioned session record rather than a
list of strings. Every item has a stable ID, original order, creation and update
times, text, typed content parts and source. Editing or moving an item preserves
its identity; recalling it restores both text and attachments to the input.

`/stage` owns the inert draft lifecycle. `/send` is the only transition from an
ordered staged batch to an executable user turn. Runtime queueing remains a
separate state: it contains already-triggered canonical drafts which wait for
the active run and then start automatically.

## Transaction Boundary

Clearing staged data at request start loses work when checkpointing or session
recording fails. The stage now clears only after the user-message checkpoint
succeeds and the canonical message has actually been added to the session. That
message keeps the staged IDs and count as provenance. A failed checkpoint or a
runtime queue wait leaves the durable stage intact.

## Lessons

- Persist typed identity and derive text projections; do not persist a display list.
- Treat staging and runtime queueing as distinct states with distinct transitions.
- Put destructive cleanup after durable acknowledgement, not before I/O starts.
- Fold only command-owned tokens. Stage subcommands accept fullwidth syntax, while
  draft text and attachment content remain byte-for-byte user data.
- Reject unknown schemas and unstructured records instead of hiding drift behind
  migration branches in a pre-1.0 design.

## Verification

- Focused staging, queue, attachment and checkpoint tests passed as part of a
  44/44 input-workflow run.
- Canonical suite passed 1,847/1,847 with zero unexpected results.
