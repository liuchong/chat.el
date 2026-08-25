# 0008 — Self-knowledge and shared storage

Status: accepted
Date: 2026-08-25

## Context

Three gaps became visible once the context budget made the cost of every
prompt region explicit.

A run cannot see its own conversation. Compaction summarizes history to
fit the window, and what the summary dropped is gone as far as the run can
tell. It is not gone from disk — the session file holds every turn — but
nothing told the run that, so it asks again or guesses.

A run has nowhere to put anything down. Material too large to hold in
context either stays in context, which is what fills a window, or gets
written into the project, which leaves litter in someone's repository.

Nothing accumulates. Whatever was worked out last session is rediscovered
or lost. There is a long term memory file, but it is curated by the user
and states what the assistant should do; there was no place for what the
assistant found out.

## Decision

Three storage places, all named in the system prompt, distinguished by
lifetime and by who writes them.

### The transcript is already searchable

The typed transcript from 0006 stamps every message with turn, step,
category and work, and the session file is JSONL. So the record is
already filterable and nothing new needs to be written to make it so.
What was missing was telling the run the file exists and giving it a
filter.

`session_log` filters on those stamps plus role, time range and literal
text. Results group by turn rather than ordering by time: a question, its
steps and its answer are one unit of meaning, and interleaving them with
everything else that happened is what makes a raw transcript unreadable.

The prompt block names the path rather than describing it. A run that has
to guess a path does not look, and one that guesses wrong reports its own
transcript as missing.

### Scratch space is per session and is deleted

Per session, because two runs writing the obvious file name should not
collide and because leftovers should be attributable. Deleted after seven
days of no changes, because a directory that only grows is the same
problem as a context that only grows, and because the honest default for
something described to the model as temporary is to actually remove it.

Pruning runs when a session opens — the moment the answer is cheap and
nothing is mid-write — and always spares the session being opened, so a
long-running session cannot lose the directory it is working in.

The scratch root goes into `chat-files-allowed-directories`. Describing a
writable path in the prompt while the file tools refuse it produces a run
that keeps retrying and cannot explain the failure.

### Shared knowledge is an index in the prompt, bodies on disk

This is the load-bearing decision. The store grows with use, and anything
injected into every request must not grow. Injecting the whole store would
put a monotonically increasing block into the fixed region and slowly
starve the working space — precisely the failure 0007 exists to prevent.

So the prompt carries note names and titles, and bodies are read on
demand. An index costs about a line per note and is still useful at a
hundred of them; it is capped anyway, falling back to the most recently
changed notes.

Knowledge notes stay separate from the user's memory file because the
trust differs. A user instruction is authoritative; a note a run wrote
about its own findings is evidence that may be stale. The prompt says so
and invites correction, because a wrong note that is treated as
authoritative is how one mistake becomes permanent.

Append is offered alongside replace. A note earns its value by being
corrected and extended, and a run that can only replace will either
clobber what it did not write or start a near-duplicate.

The store stays one global directory rather than being partitioned per
project, and pays for that with a content rule: general, desensitized
knowledge only — the technique rather than the case. Partitioning would
enforce isolation structurally but would also defeat the point, since a
note that only applies where it was written is close to worthless. The
value is in observations that transfer, and those are the same ones that
carry nothing project-specific, so the constraint and the purpose point
the same way.

The bar is set deliberately high and the prompt says to prefer writing
nothing, because this starts as an unvalidated idea: a small store whose
notes turn out to be worth reading tells us more than a large one that
has to be distrusted. Enforcement is prompt-level, since what counts as
project-specific needs judgement. Two classes do not — credential-shaped
material and absolute paths naming one machine — and those are refused
mechanically, following the precedent of `chat-files-deny-patterns`.

### The block sizes itself

Measured: the full storage block is 433 tokens, and the system prompt
share of an 8K window is 278. So on a small window the block explaining
how to recover a lost conversation would itself crowd out the
conversation.

Rather than tune per window, the block is measured against the share it
lands in and falls back to a short form when it does not fit. The short
form keeps paths and tool names and drops the reasoning. That is the right
thing to lose: a block trimmed down to advice is worse than absent, since
the run still pays for it and still cannot find the file.

## Consequences

A run can recover anything it was told, at the cost of a tool call. This
makes aggressive compaction safer than it was: what compaction drops is
retrievable rather than lost, so the working window can be spent on the
current problem.

The knowledge store is a new kind of state — written by the model,
persisting globally, and not reviewed by anyone unless someone opens it.
It is deliberately plain Markdown in a plain directory so that reviewing
and correcting it needs no tooling. Treating its contents as evidence
rather than instruction is a prompt-level guard, not an enforced one.

Scratch space deletion is a real deletion on a timer. A run that puts
something it needed in scratch space loses it. The prompt states the
lifetime for that reason, and the answer to needing something kept is the
project or the knowledge store.

The storage block is the first prompt region that varies its own
verbosity by window size. If more regions need that, the selection
belongs in the allocation layer rather than repeated per region.

## Alternatives considered

**Injecting recent transcript excerpts instead of a lookup tool.** Cheaper
to implement and needs no tool call, but it spends context on history the
run may not need, which is the problem compaction was solving. A lookup
spends nothing until asked.

**A shared scratch directory.** Simpler, but collisions between sessions
on obvious file names are certain rather than hypothetical, and nothing
could then be attributed or cleaned up as a unit.

**Folding knowledge into the memory file.** One place is simpler, but it
merges authoritative user instruction with unreviewed model findings, and
the file is injected whole — so the store growing would directly consume
the window.

**Letting the model manage its own note index.** More flexible, but the
index is what makes the store reachable at all; deriving it from the files
means it cannot drift out of date.
