# Stage log 2026-08-26 — tool call pairing, message dates, and who owns a string

- Type: records
- Attention: log
- Scope: input-commands, llm-transport, session-persistence

## What prompted it

A session refused to send. The provider answered `tool_call_id is not
found`, so nothing could be asked of a conversation that had once used
tools. Separately, `/ｈｅｌｐ` was not recognized as a command.

## What was actually wrong

**One id, two authors.** A tool call id is written into a request twice —
in the assistant's `tool_calls` and as the `tool_call_id` of the result —
and two functions supplied it, each with a fallback for calls that arrived
without an id. The call side fell back to the tool name, the result side to
the position. A turn parsed out of the reply text has no provider id, so
both fired. On the real session this advertised `files_read`,
`shell_execute` and `files_read_lines` while referring to `call-1` through
`call-7`: ten results, none matching, and the second turn reusing the first
turn's numbers. Five places in the tree minted ids, in two incompatible
schemes.

**Dates destroyed on load.** The loader wrapped `parse-time-string`, which
already returns a decoded time, in `decode-time`, which reads its argument
as a time value. Seconds and minutes were taken for the halves of an epoch
offset, so every reopened message came back dated a few weeks into 1970 —
and was written back that way. Saving was correct, which is why nothing
caught it.

**A character class named after its examples.** Fullwidth folding was a
hand-listed table of punctuation. An input method is not in fullwidth mode
for the punctuation alone; it produces `／ｈｅｌｐ`.

## What changed

One function answers the id question and both payload positions call it, so
they cannot diverge. The fallback is positional rather than name-derived,
because a turn that reads a file in chunks calls one tool repeatedly, and
qualified by the message, because a bare position would make every turn
claim `call-1`. Producers mint ids up front;
`chat-tool-caller-process-response-data` was the path that skipped the
existing `chat-agent-ensure-tool-call-ids`, which is why turns reached disk
without them. Ids are minted after `delete-dups`, which compares whole
plists — earlier, and one repeated call would run twice.

The loader now uses `encode-time`.

Folding became the arithmetic map of U+FF01–U+FF5E, and its boundary was
restated in terms of ownership rather than appearance. `！` is chat.el's
command, being shorthand for `/cmd`, so it folds; the `ls` after it is that
command's argument, content on its way to an executor, so it does not.
`/auto`, `/drop`, `/model` and `/help` read their arguments as names, so
those fold — in the handlers, since the parser cannot tell them from the
prompt in the same position one command along.

## What went wrong on the way

The test covering the working id path asserted the literal `call-1`. That
is how two fallbacks drifting apart stayed invisible: the spelling was
pinned on the path that happened to work, and the property that mattered —
that the two sides agree — was never stated. It now asserts agreement.

Decision 0005 had recorded, as a consequence, that fullwidth support could
be extended "by adding a pair to the folding table". Following that is what
left the letters out. A list of instances standing in for a range will be
extended one report at a time forever.

## What guards it

Seventeen tests. The payload check walks a request the way a provider does
— collect what each assistant advertises, flag any `tool_call_id` that
arrives unoffered — rather than asserting any particular id. The date tests
save, load and compare, and check a second reopen, because a loader that
corrupts and re-saves needs one cycle to lose the data and another to look
stable. The folding tests come in pairs: the widened positions must fold and
the forwarded positions must not, so the next widening cannot quietly
rewrite what someone is sending.

Every one of them fails with the old code restored, verified by putting the
old fallbacks, the old loader and the old table back and running them.

## Result

886 tests passing, byte-compile clean. The real session's payload pairs
with nothing left over. Its 1970 dates are not recoverable.

Not fixed: a shell body typed entirely in fullwidth mode fails in the
executor, deliberately. Decision 0014 explains why that is the rule
working.
