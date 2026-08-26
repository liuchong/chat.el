# Stage: A File Per Session

Date: 2026-08-27
Spec: 009 (session-scoped event log)

## What was wrong

One file, `~/.chat/chat.log`, held the diagnostics of every session at once.
It had reached 119MB. 106.6MB of that -- 90% -- was 77 copies of a single
conversation at 1.4MB apiece, because a clause reporting unhandled agent
events printed the event, every event carries `:run`, and the run holds the
session.

The size was the visible half. The unrecoverable half was that nothing could
be asked of the file: no session id, no turn, no schema, no rotation. "Why did
that answer take three rounds" had no answer on disk, and neither did "how
long did the vendor take before the first byte".

Sessions already had structured per-session storage for what goes *to* the
model. What was missing was what *happened*.

## What was built

Three streams where there were two, with the third being the one that was
missing:

- `~/.chat/sessions/<id>.jsonl` -- context, model input, already existed
- `~/.chat/sessions/wire/<id>.jsonl` -- events, new
- `~/.chat/chat.log` -- diagnostics, narrowed and now bounded

`chat-session-wire.el` owns the envelope, the sequence, the append, the caps
and the rotation, and knows nothing about agents. `chat-agent-wire.el`
subscribes to a new `chat-agent-event-functions` hook on `chat-agent--emit`
and projects each event type into bounded facts. `chat-session-index.el`
answers "what sessions exist" without loading them.

Plus, from spec 009's remaining items: timings now file under the session
that produced them, and compaction records itself as an event -- it is the one
operation that makes a session's history disagree with what the model was
shown, so a reader comparing the two needs to know where the disagreement
started.

## What the work found

**The event type list in the header comment was wrong.** It named fifteen;
`chat-agent--emit`'s call sites have seventeen. The spec inherited the wrong
number from the comment. The coverage test now counts them out of the source,
which is the only reason it is right.

**A directory identified by glob is a namespace.** `chat-session-list` decides
what a session is by globbing `*.jsonl` and taking the base name, so the
originally specified `<id>.wire.jsonl` would have been offered to
`chat-session-load` as a session on every listing -- silently, since the load
is wrapped in `condition-case`. Same trap for `index.jsonl`, which the rebuild
would have read as a session while walking the sessions to rebuild itself.
Both moved out: streams into a subdirectory, index above the session
directory. A filter on the glob would have worked and would have been a rule
to remember; the layout makes it impossible instead.

**The context stream's append is quadratic.**
`chat-session--atomic-append-jsonl` copies the entire file into a temp and
renames, per record. At a few records per turn that is tolerable; an event
stream produces dozens per turn, so the wire appends plainly and tolerates a
torn last line on the read side instead. (The context stream's own cost is
left alone here -- it is real but it is not this commit's subject.)

**Instrumentation added at the end of a function changes what it returns.**
Recording compaction broke a test with `(wrong-type-argument listp 392)`: the
callback received the byte count from the recorder's `puthash` instead of the
summary entry. Nothing about the added line was wrong. Recorders now return
`t`, and the entry is bound before anything follows it.

**Logging was never free when off.** `chat-log` checked its switch inside the
function, so arguments were evaluated at the call site regardless -- including
one that formatted a 250KB payload per send. It is now a macro. Safe here only
because the repo carries no `.elc` and nothing took it as a function value;
both checked, and the two `funcall 'chat-log` sites found were ones written
earlier in this same commit.

**An observer must be total.** The coverage test caught the `agent-start`
projection raising on an event with no run. An observer that can raise is an
observer that can turn a run that worked into a run that failed while being
watched.

## Deferred, with the reason

**Token usage (spec 009 §2.4) is not implemented.** Verified during the work:
nothing in the codebase reads the `usage` object at all. Capturing it means
sending `stream_options.include_usage` and handling per-vendor differences in
field names and arrival timing -- a transport change, not a recording one. The
recording side is ready; it needs one `kind:"usage"` record and no structural
change.

**First-byte latency (§2.2) needs no new plumbing.** The envelope carries
`timestamp_ms`, so the gap between `turn-start` and that turn's first
`stream-chunk` *is* the latency. Spec updated to say so rather than to
specify a field nobody needs.

## Verification

1127 tests, 0 unexpected, run twice. 31 new: envelope and sequence continuity
across a reopen, a torn trailing line, the per-record cap, archiving at the
file cap, the projection covering every emitted type and never carrying the
run, a real two-turn tool run leaving a complete account of itself in under
8KB, the index holding one line per turn rather than per message and rebuilding
from the sessions, and logging evaluating nothing when off.

One pre-existing flake seen once and not reproduced:
`chat-tool-shell-reports-nonzero-exit-status`, subprocess stderr timing.
