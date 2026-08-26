# 0010 — Rendering the transcript

Status: accepted
Date: 2026-08-26

## Context

The complaint was concrete: after a run that used tools, the buffer held
the question at the top, the answer at the bottom, and nothing in
between. Everything the run did on the way had disappeared.

The record was never the problem. The agent loop emits
`message-appended` for every step and the handler persists it
immediately, so the session file already held each step's prose, each
tool call and each tool result. Decision 0006 added the typed transcript
model on top of that: turn, step, category and work stamped on every
message, and `chat-transcript-plan` deciding what to show and what to
fold.

The display was the problem. It drew an assistant turn into one mutable
region between two markers and rewrote that region on every update. Step
N's text was deleted to make room for step N+1's. Nothing was lost from
disk and everything was lost from the screen.

Two consequences followed from that shape. Reopening a session showed
less than the live run had, because the live run's steps only ever
existed as buffer text. And `chat-ui--insert-message` drew a message by
role alone — "You", "Assistant", "System" — so even the history it did
draw had no notion of reasoning, a tool call, or prose that is not the
answer.

## Decision

The display draws the record. It holds nothing of its own.

### Two regions, because they change at different rates

Committed history runs from `chat-ui--conversation-start` to
`chat-ui--live-start` and is drawn from `chat-session-messages`. It is
redrawn when the record changes: a message appended, a message sent, a
fold toggled.

The live tail runs from `chat-ui--live-start` to
`chat-ui--messages-end` and holds only what has arrived and not been
recorded yet. It is redrawn on every stream chunk.

The split is what makes both correct and fast. One region for everything
would mean redrawing the whole conversation per chunk, which gets slower
as the conversation grows. One region for the tail only — the old design
— means the tail owns the whole turn and overwrites its own past.

`message-appended` is the handoff: the step is now on the record, so it
becomes committed history and the tail starts over. After that the next
chunk cannot reach back over it. That single line is what fixes the
original complaint, and disabling it fails eleven tests.

`chat-ui--live-start` has insertion type nil, so text arriving at the
boundary lands after it. Anything written past the committed history is
by definition the tail.

### Within the tail, append rather than rewrite

A reply arrives in many small chunks and reinserting all of it each time
is quadratic. The tail appends when the new text extends the old, and
resumes at a closed fence: cutting mid-block leaves a half-arrived code
block drawn as prose, and the fence that would have closed it is never
reconsidered.

### The answer is not drawn twice

By the time a run ends its answer is usually already recorded and on
screen. `chat-ui--finalize-response` therefore checks whether the content
is the recorded answer before rendering it as the tail. It is a question
rather than an assumption because a run cut short, or one that ends
without an answer, has nothing on the record to match.

What finalize does add is what belongs to the turn as a whole — which
tools ran, whether the step limit cut the run short — and the edit a
coding reply may be proposing.

### Typography carries the distinction the model already makes

Reasoning and tool work fold behind a summary row, because they are
detail. Prose on the way to the answer shows in italics: it is meant to
be read, it just must not be mistaken for the answer. The answer is
ordinary text and is never folded — it is not a channel.

A fold group is keyed by its first part, so it stays as the reader left it
while later parts of the same channel arrive. The row carries its own
keymap as a text property, so `RET` toggles a fold where a fold is and
still sends the message everywhere else.

### Two display concerns that belong to the display

A model that calls a tool puts the call in the content field as well, so a
step's prose arrives with a JSON blob in it. Rendered as written it reads
as the model having answered in JSON. It is stripped when a part becomes
text — and stripping can empty the prose entirely, so an emptied part is
dropped before the plan sees it, or a fold row would stand for nothing.

Tool arguments arrive as an alist. Printed as a Lisp object they read as
`(("path" . "x"))`, which is the transport showing through. They render
as `path=x`.

## Consequences

An intermediate step stays on screen once recorded. A reopened session
shows what the live run showed, because both draw the same record through
the same code.

`chat-ui--insert-message` no longer renders by role; it renders the
message's transcript parts, so a message drawn as it arrives looks like
the same message drawn from the record after a reload.

`chat-ui--live-response-start` is gone. Nothing read it once the tail was
positioned from the record, and a variable that is only ever assigned is
worse than no variable.

`chat-ui--render-response-state` keeps its name and its argument list —
callers written against the mutable slot still work — but its
`content-start` argument is ignored. The tail is positioned from the
record now, not from where a caller happened to leave a marker.

Every render walks the session's messages and rebuilds the parts. At the
sizes a chat session reaches this is not worth caching, and a cache is
how the display got out of step with the record in the first place. If a
long session ever makes a fold toggle feel slow, the fix is to redraw
from the last user message rather than to start keeping state.
