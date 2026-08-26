# Stage — Rendering the transcript (2026-08-26)

## What prompted it

A run that used tools left the buffer holding the question at the top,
the answer at the bottom, and nothing in between. Everything the run did
on the way had disappeared from the screen.

The record was fine. `message-appended` fires for every step and the
handler persists it, so each step's prose, each tool call and each tool
result were on disk the whole time. The display drew an assistant turn
into one mutable region and rewrote that region per update, so step N's
text was deleted to make room for step N+1.

## What changed

The display now draws the record and holds nothing of its own.

Committed history runs from `chat-ui--conversation-start` to
`chat-ui--live-start`, redrawn from `chat-session-messages` when the
record changes. The live tail runs from there to
`chat-ui--messages-end` and holds only what has arrived and not been
recorded, redrawn per chunk. `message-appended` is the handoff between
them: the step becomes committed history and the tail starts over, so the
next chunk cannot reach back over it.

Within the tail, rendering appends when the new text extends the old
rather than reinserting the whole reply, and resumes at a closed fence so
a half-arrived code block is not drawn as prose.

Typography follows the channel the transcript model already assigns.
Reasoning and tool work fold behind a summary row; a call and its result
are one group, keyed by the group's first part so it stays as the reader
left it while later parts arrive. Interim prose shows in italics. The
answer is ordinary text and is never folded. `RET` on a row toggles it
through a keymap carried as a text property, so `RET` still sends the
message everywhere else; `C-c C-d` toggles everything.

Two display-layer fixes came out of looking at real output rather than at
assertions: tool-call JSON is stripped from a step's prose before it is
drawn, and a part that stripping empties is dropped so no fold row stands
for nothing; and tool arguments render as `path=config.el` instead of
`(("path" . "config.el"))`.

## What went wrong on the way

Two tests kept passing while the thing they named was broken, because
they were written against the mutable slot: they set
`chat-ui--live-response-start` and asserted on a `content-start` region.
Both are gone now — the variable was only ever assigned, and
`content-start` is accepted and ignored so older callers still work.

The assertions were all green before the output was ever looked at. The
raw JSON in interim prose and the alist syntax in tool calls were both
found by rendering a realistic turn and reading it, not by a test.
`chat-ui-transcript-never-shows-the-tool-call-as-prose` passed on the
answer while the interim step still carried the blob.

The batch harness needs `(require 'chat)` for the provider registry;
requiring `chat-ui` alone fails with `Unknown provider: kimi`.

## What guards it

781 tests, all passing. New file
`tests/unit/test-chat-ui-transcript.el` carries 20 covering the
invariants: an intermediate step stays on screen, the tool call never
reads as prose, the answer is drawn once, a reopened session shows what
the run showed, folds start closed and toggle, interim prose is italic
and the answer is not, streaming appends only the delta, and the tail
does not eat a committed step.

Disabling the `message-appended` handoff fails eleven of them — measured,
not assumed.

## Result

An intermediate step stays on screen once recorded. A reopened session
shows what the live run showed, because both draw the same record through
the same code. `chat-ui--insert-message` renders transcript parts rather
than dispatching on role, so a message drawn as it arrives looks like the
same message drawn from the record after a reload.
