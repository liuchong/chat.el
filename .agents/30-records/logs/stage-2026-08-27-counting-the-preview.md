# Stage: Counting The Preview Instead Of The Payload

- Type: log
- Attention: record
- Status: done
- Scope: project
- Date: 2026-08-27
- Tags: context-budget, correctness, allocation, gc, responsiveness

## What Was Asked

Two questions about the ~900ms stall, both of which redirected the
investigation:

- Is the data structure wrong? String concatenation should be cheap, and
  Clojure would share structure rather than produce 165x.
- The hitch is at RET, before any request. So whatever accumulated must
  have accumulated earlier. What was it?

## The First Question

Structure sharing does not apply. Clojure's persistent vectors and maps
share nodes; its strings are `java.lang.String` -- flat and immutable, so
`(reduce str chunks)` is quadratic there too, and the idiom is a
StringBuilder or one `(apply str coll)`. Emacs Lisp strings are the same
shape and `concat` always copies.

So the diagnosis stands but the framing was wrong: this is not a language
limit, it is a flat immutable string used as an append accumulator. Emacs
has the right container for that -- a buffer is a gap buffer and appends
in amortized constant time -- and a list of chunks materialized once is
the other answer.

## The Second Question, Which Was The Useful One

Correct, and it reframes the whole thing. `gc-cons-threshold` counts bytes
consed since the last collection, without regard to who consed them.
Whoever crosses the line pays. So the question is not what the send is
about to do but how large a share of the threshold the send contributes,
because that share is its chance of being the one to cross.

Measured on the real session, a send allocated **12.4MB** against a
threshold of 100MB (their Spacemacs sets `dotspacemacs-gc-cons
'(100000000 0.1)`, so the usual advice to raise it is already taken).
Roughly one send in eight would be the one to cross. Four timed sends
showed one stall. Consistent.

Then the attribution: 11.3MB of the 12.4MB was in two calls, and one of
them turned out not to be a performance finding at all.

## What Was Wrong

`chat-context-message-tokens` counted the **snippet** of each message's
tool calls and tool results -- the 120-character preview a durable summary
shows -- while the request carries both in full.

```
payload actually sent:   252677 bytes (~63170 tokens)
what the budget counted:   5295 tokens
counting what is sent:    44329 tokens
under-count factor:          8.4x
```

A 100KB tool result is some 25,000 tokens on the wire and was counted as
30. So on any tool-heavy session the budget believed it had room it did
not have, and auto-compaction sat still because by its own arithmetic
there was nothing to compact. This is a correctness bug that happened to
be found while chasing allocation.

And to produce that unusable number it concatenated every tool result,
ran a whitespace regexp over the whole thing, trimmed it and kept 120
characters: 5.73MB and 22.6ms per send.

The other 5.19MB was the cold read of project instructions, which the
cache from two stages ago already reduces to once per Emacs rather than
once per send. Not a per-send cost.

## What Was Done

- Token counts come from the fields the request carries, by `length`, with
  the transport's own encoding rule mirrored for arguments that are not
  already strings. **22.6ms and 5.73MB became 0.2ms and 0.09MB, and the
  count went from 8.4x under to matching.**
- `chat-context--message-snippet` takes a head of four times the column
  cap before collapsing whitespace. Collapsing 200KB to keep 120
  characters copied the 200KB twice; the snippet functions cut each piece
  before joining, so one tool call carrying a file is not copied whole to
  contribute a few words.
- Per-send allocation: **12.4MB to about 1.6MB.** One send in eight
  crossing the threshold becomes roughly one in sixty.

## Still Open

**The streaming accumulator, and it is now the dominant allocator.**
`chat-agent-loop.el` rebuilds the whole response on every chunk. Replayed
through the real event handler, the worst response in the log -- 340
chunks, 321KB -- allocates **59MB, of which 52MB is the accumulator**.
Two such responses fill the 100MB threshold on their own.

Removing it is not a local change. Both consumers want the whole string
on every chunk: `chat-tool-caller-extract-content` scans it for tool-call
payloads that may straddle chunks, and `chat-ui--render-response-state`
renders the live region as a pure function of the whole content -- which
is a deliberate contract, not an accident. A buffer or a chunk list fixes
the accumulation but not the handover, since materializing per chunk costs
the same copy. So the fix is to make the live tail append, and that is a
design change with its own risk. Not started without a decision.

## Verification

1091 tests pass, 3 new. Worth recording that **1088 passed with the count
8.4x wrong**: every test touching the budget asserted behaviour around a
threshold using messages it had built itself, and none asserted that the
count tracks what goes on the wire.
