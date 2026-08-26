# Stage: The Hundredfold, And The One Behind It

- Type: log
- Attention: record
- Status: done
- Scope: project
- Date: 2026-08-27
- Tags: allocation, streaming, rendering, gc, responsiveness

## What Was Asked

Whether the 165x accumulation was fixed, and to fix it -- committing first
if it looked large enough to need a way back.

It was not fixed. The previous stage had measured it and left it, on the
grounds that both consumers wanted the whole string on every piece.

## What The Code Actually Said

That reasoning was half wrong, and reading the renderer before touching
anything is what showed it. `chat-ui--render-live-region` has appended
since it was written: it keeps the last content, checks `string-prefix-p`,
finds a fence-safe boundary, and inserts only `(substring content cut)`.
The buffer work was already incremental. The whole 52MB was the
accumulator in `chat-agent-loop.el` and nothing else.

That made the fix local rather than a redesign.

## The Accumulator

Pieces go into a list and become one string only when the reply is
published, and publishing backs off as the reply grows: while the text is
short every piece publishes, and past that a piece publishes once the
unpublished tail reaches an eighth of what is already out.

Replayed against the log's worst reply, 340 pieces totalling 321KB:

| | handovers | time | allocated |
| --- | --- | --- | --- |
| `(concat all piece)` | 340 | 44.1ms | 53.6MB (171x) |
| back off at 1/8 | 36 | 0.4ms | 3.3MB (10x) |
| back off at 1/4 | 22 | 0.4ms | 2.1MB (7x) |
| back off at 1/1 | 9 | 0.4ms | 1.2MB (4x) |

An eighth is the default because a reply under about 8KB still publishes
on every piece, so nothing common gets chunkier. What a long one gives up
is that its tail arrives in 36 steps instead of 340 -- text arriving faster
than it can be read.

Two things this needs to be safe, and both are asserted: the end of a run
flushes whatever never reached the threshold, or a reply silently loses its
tail; and the pieces, when published together, are exactly what arrived.

The transport had the same shape for reasoning deltas, rebuilding the whole
trace per delta on a process property read once at the end. That one is
just a `push` and a `reverse` on read -- with a test, because the reverse
is the kind of thing that works until it is the thing that is wrong.

## The One Behind It

Backing off made the end-to-end measurement *worse* in allocation while
much better in time, which only happens if something downstream is
superlinear in what it is handed. Measuring drawing alone at four sizes an
octave apart:

| input | time | allocated | per 100k |
| --- | --- | --- | --- |
| 4.7KB | 2ms | 0.33MB | 7.1MB |
| 19KB | 1ms | 3.86MB | 20.0MB |
| 78KB | 43ms | 60.4MB | 77.4MB |
| 320KB | 592ms | 986MB | 308.2MB |

Four times the text, four times the cost *per unit*: quadratic, cleanly.
`chat-ui--insert-formatted-response` searched `(substring content pos)` for
the next fenced block and then took the same copy again to read the match
groups -- two copies of everything remaining, per block. 986MB is ten
collection thresholds to draw one reply once.

`string-match` takes a start offset and leaves match data in the original
string's coordinates. Flat at 0.5MB per 100k afterwards; 320KB went from
986MB and 592ms to 1.74MB and 5ms.

The offset is also the more correct reading. `^` matches at the start of
the string it is given, so scanning a copy let a fence match wherever the
copy began -- mid-line, mid-paragraph. From an offset it matches only where
a line starts.

Nothing covered this function at all. It has three tests now: the shape
(four times the text may not cost sixteen times as much), the faces and
prose surviving a draw, and the half-arrived block of a reply still
streaming.

## Together

The log's worst reply, through the accumulator and the renderer both:

| | updates | time | allocated | collections |
| --- | --- | --- | --- | --- |
| before | 341 | 689ms | 73.5MB (233x) | 5, 45ms |
| after | 36 | 34ms | 5.9MB (19x) | 0 |

## What This Is Not

It is not the first send's 924ms. Real sessions hold small messages -- the
largest here has 41 of them, 19KB in total, longest 8KB -- so a redraw
costs 0.6MB and neither of these costs was ever on the keystroke path.
Both were filling the 100MB threshold *during* a long reply, which is how
the collection comes to land on whatever allocates next, a keystroke
included. The first send after a restart is still paying for startup
garbage that this program did not produce.

Fixing an allocator and fixing a stall are different claims. The
measurement supports the first.

## Verification

- 1100 tests passing, from 1091: seven added.
- Three changed files byte-compile with no new warnings.
- Benchmarks run against the real session files and the log's real chunk
  distribution, not synthetic best cases.
