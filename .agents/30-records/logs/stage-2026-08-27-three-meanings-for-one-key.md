# Stage: Three Meanings For One Key

Date: 2026-08-27
Spec: 010 (sending while something is running)

## What was wrong

Pressing return during a reply had one behaviour, and nobody had chosen it:
the input was written to the session, queued, and injected into the run in
progress before its next step. That is the right answer to one of three
questions people are actually asking:

- adding to what they asked -- injection is right
- wanting the current job finished first -- injection mixes two jobs into one
  turn
- having changed their mind -- injection is worst, the model carries on with a
  withdrawn task

Two further problems on the same path, both confirmed rather than assumed:

**Injected messages had no structure.** Three inputs drained into three
`:user` messages, and `chat-llm--format-one-message` puts only role and
content on the wire -- the struct's timestamp and id do not travel. So the
model saw three adjacent user turns with nothing to distinguish a correction
from an addition, or to say which was latest.

**Steering spent the step budget instead of bringing any.** `max-steps` was
untouched while every steered turn still incremented `step`. A question that
used six of eight steps left the correction two, and the correction is usually
the part that mattered.

## What was checked before changing anything

The spec's Current Status section records this in full. In short:

- **Context continuity already works.** A new `/send` takes its messages from
  `chat-session-messages` via `chat-transcript-model-messages`; previous
  assistant messages, their `tool_calls`, and the separate `:tool` result
  messages are all in it. No change needed, and none made.
- **Compaction already works and is automatic**, triggered per step through
  `transform-context-fn`, and `chat-context--compaction-plan` will not cut a
  `tool_calls` away from its results.
- **The "incompressible region" is not what it sounded like.**
  `chat-context-resident.el` protects marked spans of *instruction files* from
  the character cap on instruction text. `chat-context--compaction-plan` never
  calls into it. Session-message protection consists of two things: leading
  system messages, and tool-pair integrity. The ability to mark messages in a
  session as never compactable **does not exist**. Recorded in the spec as a
  non-goal needing its own spec, not quietly implemented here.
- **Interruption discarded the partial reply.** Cancelling makes the stream
  sentinel skip the result handler, and the UI's `cancelled` branch only
  cleans up. So "the partial result is carried forward as context" had nothing
  to refer to; that had to be built before `interrupt` could mean anything.

## What was built

`insert` (default, unchanged in shape):

- each injected message is introduced on the wire by
  `[input 2 of 3 · 02:41:07 · arrived while you were working]`, or, when it is
  alone, `[arrived while you were working · 02:41:07]`. Marker in English
  regardless of interface language: it is read by the model, not the user, and
  localising it would make the same situation look different per user for no
  gain. The copy in the session and on screen stays unmarked -- there the
  marker is noise.
- `chat-agent-steer` raises `max-steps` to `step + step-budget`, a new slot
  holding what one input is worth. Unbounded on purpose: each refresh takes a
  human pressing return, and a human is the exit from that loop. A model
  cannot steer itself, so the original limit still bounds a model in circles.

`queue`: held in the buffer, sent as its own run when `agent-end` arrives in
any status, one at a time, in arrival order. Through a timer, so the send does
not run inside the event handler of the run it was waiting for.

`interrupt`: the streamed text so far is written into the session as an
assistant message marked `[interrupted after N characters]`, then the run is
cancelled, then the input goes out as a new run -- which now sees the partial
answer in its context.

## The design problem worth recording

`/send queue 修一下` is ambiguous: is `queue` a mode or the first word of the
message? It cannot be resolved by cleverness, because both readings are
plausible.

What resolved it is that plain input and `/send` reach the *same handler*
(`chat-ui--dispatch-plain-input` looks up the sticky default, which is
`chat-ui--command-send`). So reading mode words from both would mean that
typing `queue the build for tomorrow` sent "the build for tomorrow" and
queued it -- eating a word the user typed, silently. Reading them only from
the explicit form is defensible: asking for `/send queue ...` is a choice,
typing is not.

Signalled with a dynamic variable, `chat-ui--input-was-typed`, bound by the
plain-input path. Which caught its own trap: declared next to its use, it sat
*after* the two `let` bindings in the file, so the bindings compiled as
lexical and did nothing whatsoever. Byte-compilation said so; loading from
source would not have.

`/send <mode>` alone sets the default, which also settles what a mode name
with nothing after it means.

## Verification

1142 tests, 0 unexpected. 12 new for the modes, 3 new for steering structure
and budget, 3 existing steering tests updated -- they asserted the exact
content of injected messages, which now carries the marker, so they match the
content and assert the marker separately.

Byte-compiles with no warnings in the changed files.
