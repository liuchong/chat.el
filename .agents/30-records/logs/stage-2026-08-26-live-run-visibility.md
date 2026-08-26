# Stage: a run you can watch happen

2026-08-26. Commits `f6349e7`, `52d8ab5`, `d39d8c7`, `79bf7d5`, `da4c391`.
Suite 945 to 984.

## What was reported

A streaming answer appeared only when the request finished. Before that,
twenty seconds with nothing on screen but an echo-area line, then a stall
notice reading `Stream started but no chunks have arrived yet.`

## What the log showed

`~/.chat/chat.log` settles it, and it is not the transport.

- 18:30:44 curl starts. Request body 308134 bytes.
- 18:31:04 first byte. Twenty seconds of genuine time to first token.
- 18:31:04 to 18:31:45 bytes arrive continuously, in bursts of tens of
  kilobytes every few seconds.
- 18:31:45 process finishes.

So the provider streamed for forty-one seconds and the screen sat still
for all of it.

## Four defects behind one symptom

**The event black hole.** `chat-ui--make-agent-event-handler` was a `cond`
with six branches and no final clause. The agent emits seventeen event
types. `stream-reasoning` was one of the eleven that fell off the end, so
every reasoning token the transport parsed, accumulated and emitted was
discarded without a word. This is the whole of why the screen was still: a
reasoning model does its thinking there.

A dropped event has no symptom of its own. It is not an error, not a
crash, not a wrong value -- it is an absence, and the only thing the user
sees is a program that appears to have stopped. That is why the event
contract is now a rule in `AGENTS.md` and a test rather than a habit.

**Reasoning recorded nowhere.** Content chunks recorded a `stream-chunk`
diagnostic; reasoning recorded nothing. So the trace believed the request
had produced nothing at all, and the stall notice was not merely unhelpful
but false: chunks were arriving the entire time it claimed none had.

**Nothing said how long.** `Streaming, waiting for first chunk` carried no
number. A message that does not change cannot distinguish a request that
is working from one that has died. It now counts the seconds, and the
surface already refreshes once a second, so it moves without a new timer.

**Streaming off by default.** `chat-ui-use-streaming` defaulted to nil,
which routes through a completion callback and delivers the whole reply at
once by design. It was also declared twice, a `defvar` at the top of the
file and a `defcustom` near the bottom. `custom-declare-variable` leaves an
already-bound variable alone, so the `defcustom` value was dead and
`customize` edited a setting the code never read. Both values happened to
be nil, which is why nothing ever looked wrong.

## The record was a model nobody wrote to

`chat-transcript` has carried turn, step, category, work and reasoning for
a while, with fold styles and faces already keyed to them. Grep found the
stamping API called only from tests. The agent loop built its messages
plain, so a multi-round run reached disk as a flat list and the display
inferred everything from roles -- which cannot tell an intermediate step
from a final answer, or a thought from a tool result.

An unused API is worse than a missing one. A missing one is visibly
missing; this one made the codebase look finished.

Messages are now stamped where they are made. The turn number is settled
once per run, because steering adds a user message mid-run and recounting
afterwards would file the rest of that turn under the next one.

## Notes for later

`stream-reasoning` names its accumulation `:reasoning` and its delta
`:text`. `stream-chunk` names the same two `:content` and `:text`. Reading
`:content` on a reasoning event yields nothing, silently.

Batch windows report their end as the end of the buffer regardless of what
the buffer holds, so no arrangement of a test window can tell a
scrolled-up reader from one at the bottom. The follow rule was extracted
into `chat-ui-window-follows-p` and tested as a rule. Naming it was worth
doing anyway: it is the whole of the promise that a reader who scrolled up
is left alone.

The keymap-versus-help test needed widening, not weakening. Its
unprefixed-key regexp is anchored and matched one key, so the pair form
`M-p / M-n` read as `M-p` alone and `M-n` was reported undocumented while
the help documented it plainly. The prefixed regexp already read both
halves of `C-c C-n / C-c C-l` because it is not anchored.

## Still open

`specs/004` acceptance items covering the committed transcript rather than
the live tail: folding a second reasoning segment when a third arrives,
and manual unfold surviving a redraw. The machinery for both exists in
`chat-transcript`; what is new is that stamped records now reach it, so
these are checks to write against real data rather than features to build.
