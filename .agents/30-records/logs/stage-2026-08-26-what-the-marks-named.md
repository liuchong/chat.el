# Stage: What The Marks Named

- Type: log
- Attention: record
- Status: done
- Scope: project
- Date: 2026-08-26
- Tags: responsiveness, instrumentation, timing, logging, method

## What Was Asked

"The first one I sent hitched, later ones didn't." Sent four times to
produce evidence, which is what the previous stage's instrumentation
needed to be worth anything.

## What The Line Said

Four sends from the real session, one line each:

```
23:49  prompt 1 history 18 record 3 redraw 3 live 1 PAINT 2 start 1381   total 1409
00:01  prompt 1 history 18 record 3 redraw 3 live 1 PAINT 2 tools 5 context 924 start 245   total 1201
00:02  prompt 1 history  0 record 2 redraw 5 live 1 PAINT 2 tools 2 context  29 start 286   total  330
00:02  prompt 2 history  1 record 4 redraw 5 live 1 PAINT 2 tools 3 context  29 start 291   total  338
```

Two facts, both from the numbers rather than from a theory:

- **Keystroke to painted question is 28ms to 33ms on every send**,
  including the first. The forced paint holds. That part of the complaint
  is closed.
- **The hitch that was still being felt is after the paint.** The
  question is on screen and the editor is dead: 1.17s on the first send,
  ~290ms on every send after. The reader is not wrong to call that a
  hitch, and the previous stage was wrong to assume it would go unnoticed
  because the model takes ten seconds anyway.

`context` at 924ms once and 29ms three times running is the shape of a
collection, not of expensive work. Compaction on a copy of that exact
session, forced by halving the limit, is 28.6ms and one full session save
at 23.8ms -- nowhere near 924. So the phase was charged for garbage it
did not create.

## What Was Built

**Every phase is charged for the collection that happened inside it.**
The line now carries `[gc N, Mms]` on any phase that provoked one, and a
total. This is the difference between a phase that did expensive work and
a phase that allocated past the threshold on everyone else's behalf, and
no amount of reading the code distinguishes them.

**The clock moved from the UI into `chat-log`.** A clock that only marks
at the door can say the room is slow but not which piece of furniture:
the 245ms to 291ms in `start` was one call into the agent. The transport
and the request builder now mark their own phases -- `steer`,
`transform`, `budget`, `headers`, `build`, `encode`, `log`, `spawn`,
`diagnostics` -- and `spawn` is deliberately its own phase, because
forking is the one cost on this path that cannot be measured anywhere but
the sender's Emacs: it scales with the heap the parent has accumulated,
and a batch process has almost none.

**Three wastes on the keystroke path, found by weighing the phases
against the real session and removed:**

- Every request printed its whole formatted payload through `%S`: a
  second formatting pass, a quarter of a megabyte of `prin1`, appended to
  a log past a hundred megabytes. `chat-llm--build-request` went from
  7.4ms to 0.7ms and stopped writing 250KB per send. The line now reports
  the shape -- 41 messages, 250k chars, roles -- which is what anyone
  reading the log actually wants.
- `executable-find "curl"` ran on every request, walking `exec-path` and
  stat-ing each entry: 11ms to 15ms, to answer a question whose answer
  does not change while Emacs runs. Looked up once now.
- The UI prepared the context and handed it to a run that prepares the
  context before every step, so the same history was compacted twice per
  send -- and a compaction rewrites the entire session file.

Also four consecutive `chat-log` calls in the transport merged into one,
since each opens the file, appends and closes it.

## Decisions

**The paint is not the fix, it is the floor.** It settles what the reader
sees; it does nothing about the command loop being blocked afterwards.
The comment claiming the preparation was "a few milliseconds" was wrong
by two orders of magnitude and has been corrected in place rather than
left to mislead the next reader.

**No deferral onto a timer.** It was considered for the post-paint work
and rejected for now: an idle timer blocks input just the same when it
fires, so it relocates the pause rather than removing it, and it would
cost the synchronous contract the send path is written against. Cheapen
first, and only move what stays expensive.

**Still unnamed: roughly 200ms of the per-send `start`.** Measured piece
by piece against the real session here, everything on that path adds to
about 60ms -- 23ms context, 0.7ms build, 3ms encode, 15ms `executable-find`,
15ms fork -- of which 30ms has now been removed. The remainder does not
exist on this machine, which is exactly the situation the phase marks were
built for. The next send will say whether it is `spawn` (a fork against a
large heap) or something else, and no fix will be guessed at before then.

## Verification

1088 tests pass, 4 new:

- The transport marks its own phases, with `make-process` stubbed by a
  process created before the stub is installed -- a stub reaching for
  `start-process` lands back in itself, which is `excessive-lisp-nesting`
  rather than a useful failure.
- A phase is charged for the collection it triggered, and the phase
  before it stays clean.
- Building a request does not log the request: a distinctive sentence of
  user content is absent from the log, and the shape is present.
- `curl` is located once, and a missing `curl` still errors every time
  rather than being remembered as absent.
