# Stage: The Paint That Might Not Happen

- Type: log
- Attention: record
- Status: done
- Scope: project
- Date: 2026-08-26
- Tags: responsiveness, redisplay, gc, project-instructions, cache

## What Was Asked

RET on a send still hitches. Nothing appears the instant the key goes
down.

## What The Measurements Said

An earlier stage had already put a paint before the request and recorded
the preparation at "about 17ms", which was the wrong number measured the
wrong way. Instrumenting the whole path by phase this time:

| phase | cost |
| --- | --- |
| draw the input prompt | 1.4ms |
| write the input history file | 1.1ms |
| append the message to the session file | 1.9ms at 361KB, 3.5ms at 1MB |
| redraw the whole conversation | 1.4ms at 40 messages, 17.9ms at 400 |
| `redisplay` | the paint |
| prepare the request | 3.2ms steady |

So six to twenty-five milliseconds of work before the paint, growing with
the length of the conversation. None of that is a hitch.

Then the same send measured 3ms once and 400ms the next time, and
instrumenting the callees blamed a different one each time -- project
instructions on one run, the system prompt on another. That is the
signature of measuring something that is not there. `gcs-done` and
`gc-elapsed` around the path found one collection every second or third
send, billed to whichever function happened to be running.

## Two Defects

**The paint was the preemptible kind.** `(redisplay)` does nothing at all
when input is pending; it returns nil to say so, and nobody read the
return value. A send is exactly when something is likely to be queued --
a held key, an autorepeat, a second RET behind the first -- so of every
paint in the program, the one placed specifically to rescue the send was
the one most liable to be skipped. `(redisplay t)` is the forced version.

**The allocation that bought the collection was repeated work.** Every
send re-read every applicable `AGENTS.md` off disk, 20KB to 30KB here,
and re-ran the resident-span partition over the result. The answer is the
same on every send until a file changes.

## Decisions

**Cache the contents, not the search.** The walk that finds the
instruction files is under a millisecond and is left alone: caching it
would miss an `AGENTS.md` newly added in an intermediate directory. So
every call still walks and still stats what it finds, and a hit saves
only the reading and the parsing. A changed, added or removed file is
noticed on its own.

**The cap is part of the key.** The file set leaves its trace in the
stamps, but the size cap does not, so a changed cap would have been
served the old truncation.

**Allocate less rather than collect later.** Raising `gc-cons-threshold`
around the send was considered and rejected: a deferred pause is still a
pause, and it lands somewhere less predictable, trading a measurable
problem for an unmeasurable one. The effect is worse in a long-lived
Emacs with a raised threshold, where rarer collections over a larger heap
are exactly the several-hundred-millisecond kind.

**The conversation redraw was left alone.** It grows with the length of
the conversation and is the largest pre-paint term at 400 messages, but
its contract is deliberate and load-bearing: the record is the only
source, so an appended message, a toggled fold and a reopened session all
produce the same screen. An append path beside it would be a second way
to draw, which is what that contract exists to prevent. Recorded here
with its measurement so the next person does not have to rediscover the
shape of it.

## Verification

1082 tests pass, 7 new. The forced paint is asserted in the source, since
batch mode never paints and reports no window worth painting into, so a
test that called it could not tell `(redisplay)` from `(redisplay t)`.

The cache is tested for the thing that matters in both directions: a
second ask reads no files, and a changed file, a file added further up the
tree, a removed file, a changed cap and a different directory each get a
fresh answer.

Measured after, on the same harness as before:

| | before | after |
| --- | --- | --- |
| keystroke to paint | 4.5ms | 1.5ms |
| one send, warm | 5-13ms | 3.2-3.7ms |
| collections over eight sends | 3 | 0 |
| allocation per preparation | 26,277 cons | 13,796 |
| project instructions per send | 1.6ms | 0.2ms |

Halving the allocation is what removed the collections from the sample,
which is the term that was producing the hitch.
