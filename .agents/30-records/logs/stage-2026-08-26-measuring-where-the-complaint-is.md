# Stage: Measuring Where The Complaint Is

- Type: log
- Attention: record
- Status: done
- Scope: project
- Date: 2026-08-26
- Tags: responsiveness, instrumentation, timing, method

## What Was Asked

RET still hitched after the previous stage. The report was specific: from
pressing RET to the typed line appearing, and the expectation that sending
should paint at once and do its work afterwards.

## The Method Was The Problem

Three rounds went into reproducing the path outside the session where the
complaint happened, and all three located nothing:

- Batch mode said every phase was single-digit milliseconds, and made
  garbage collection look like the largest term. It was the largest term
  *in batch*, over a small heap, with no display and no hooks.
- A real GUI frame was built to test whether the prompt marks were paying
  for a font fallback on macOS. `char-displayable-p` on the marks is
  0.018ms cold and free warm. Wrong guess.
- The transport, the body encoding and the log file were each measured and
  cleared: `curl` through `make-process` is asynchronous, `json-encode` of
  the real 325KB payload is 0.3ms, and an 81MB log costs nothing to append
  to.

None of that could have found the answer, because the costs that decide
whether RET feels instant live in the display and in whatever hooks the
reader's configuration installs, and neither exists in batch mode or in an
`emacs -Q`. Meanwhile the program itself logged nothing between the
keystroke and the prepared request, so the one window under discussion was
the only part of the path with no record.

## What Was Built

The send path measures itself and says so in one line: the phases in the
order they run, the mark before the paint separated out because everything
ahead of it is what stands between the keystroke and the reader seeing
their own question, and the facts that would explain an outlier -- buffer
size, message count, whether undo is recording and how long its list is,
and how many `post-command-hook` and `after-change-functions` entries are
installed. Those last three are exactly what a large configuration adds
and a bare Emacs does not have.

## What It Said

First line out of the real session, on a 34-message code session:

```
prompt 1 -> history 18 -> record 3 -> redraw 3 -> live 1 -> PAINT 2
| total 1409ms | buffer 11k, 34 messages, undo 27, 5 post-command hooks,
2 change hooks
```

Keystroke to painted question: 28ms. The reported hitch is gone, and the
forced paint from the previous stage is why -- the work ahead of it was
never the problem, and the preemptible `redisplay` was.

The same line also showed 1381ms after the paint, in one unbroken phase.
Emacs is blocked for that whole time. It goes unnoticed because the reader
is already waiting on the model -- that response took ten seconds -- but
it is the command loop, and anything typed into it waits.

Measured separately, the pure-Lisp preparation does not account for it:
building the code context is 0.7ms, the capability prompt 0.2ms,
`chat-ui--prepare-messages-with-tools` 6.8ms and
`chat-context-prepare-messages` 17ms on the real session, against a
compaction limit of 222,822. Some 25ms of the 1381 is explained. The
remainder is inside `chat-agent-start` and below.

## Decisions

**One unbroken phase holding 98% of a send is an instrument failure, not a
finding.** The marks were split so that the next send attributes it:
`tools`, `context` and `start` are now separate, which divides the blob at
the two places the work changes hands.

**No fix was attempted for the 1381ms.** Three wrong guesses in a row is
enough evidence that guessing here does not work. The next real line will
say which of the three phases holds it, and that is a cheaper way to be
right than another round of reproduction.

**Noted but not touched**: undo recording is on in the chat buffer, and
every send rewrites the whole transcript, so tens of kilobytes are copied
into the undo list per send. The undo list was only 27 entries long in the
measured session, so it is waste rather than the cause, and it stays as it
is until a measurement says otherwise.

## Verification

1084 tests pass, 3 new: the timing line is logged with its phases in
order, the phases are named finely enough to attribute a cost, and the
whole thing goes quiet under `chat-ui-log-send-timings`.
