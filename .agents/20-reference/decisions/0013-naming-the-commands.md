# 0013 — Naming the commands, and what auto returns to

## Context

Four things arrived together and turned out to be one thing.

A user reported that auto was broken: after one `!ls`, typing `pwd` still
went to the shell, an explicit `?question` worked but changed nothing, and
the line after it went to the shell again. Reproduced exactly as
described.

It was not a bug. Decision 0011 declared only `/cmd` repeatable and wrote
down why: `/ask` asks without recording, so as a sticky default it would
quietly stop the conversation being written down. That reasoning was
right. The conclusion was wrong, and the same note said so without
noticing — it justified `/ask` not being sticky by saying asking the model
"is already what plain input does", which is a statement that plain input
has a behaviour worth naming and no name for it.

The same session asked what `/ask` and `/question` differ in. Nothing:
they were separate table entries sharing one handler. With `/?` and the
`?text` prefix, that made four names for the ephemeral aside and none at
all for the recorded conversation — the surface's whole point had no name,
and the thing you reach for occasionally had four.

And `/help` promised `/wiki-*`, `/new`, `/save` and `/clear`, none of
which existed, while `/ask`, `/question`, `/?` and `/!` all worked and
appeared nowhere in it.

## Decisions

**The main path is a command.** `/send` sends a message, records it, and
lets the run use tools over several steps — which is what plain input has
always done. Naming it is what makes the rest of this possible.

**One entry per command; everything else is an alias.** `/ask` and
`/question` are spellings of `/send`, `/?` of `/quick`, `/!` of `/cmd`,
registered through the same alias mechanism that carries `/自动`. Two
entries sharing a handler is how four names for one thing accumulated;
the fix is structural, not editorial.

**`/ask` means the conversation, not the aside.** It reads as "ask the
model", and the ephemeral one-shot is now `/quick` — which also matches
the `Assistant (quick)` label it has always been drawn under.

**Three default effects instead of a boolean.** `sticky` claims plain
input, `reset` hands it back to `/send`, nil leaves it alone. The
baseline is `/send`, so there is always somewhere to return to.

`/quick` resets rather than sticking. Decision 0011's reasoning holds and
gets stronger with a name attached: sticky, it would answer every
following line and record none of them, and nothing on screen
distinguishes an answer that was written down from one that was not.
Resetting still gets a reader out of shell mode, which is what actually
went wrong.

**The prompt says who holds the line.** `cmd> ` rather than `> `. The
status line already said `auto: /cmd`, and it was not enough: it is at the
top of a buffer that scrolls and the cursor is at the bottom. The
reported failure was typing a question into what looked like a chat box
and having it run as a command.

**Two language switches for the model, not one.** `chat-reply-language`
is what the model is told to answer in — the reliable lever, since models
follow "answer in Japanese" regardless of the instruction's own language.
`chat-prompt-language` is the language of the instructions themselves,
and it is separate because it is not cosmetic: translated guidance
changes behaviour in ways that cannot be measured from inside Emacs.
Contracts — JSON keys, tool names, patch envelopes, fence languages — are
never translated at either setting, because a parser matches them
literally.

The coding rule lists stay English while the persona around them is
translated. They are dense with literal tool names, so a translation
would have to carry every one of them through untouched, for no change in
what the model does.

**Queued notes join into one message.** Consecutive messages in one role
are not something every provider accepts, and a batching feature that
works on some models is worse than one that reads slightly less
faithfully on all of them. Numbered when there are several, so the model
can see it was given distinct requests; unnumbered at one, because
numbering a list of one is noise.

## What guards it

The slash-command consistency test now runs both ways. It only ever
checked that documented names had handlers, which is why four live
commands were undocumented: a one-way consistency test is a blind spot
with a passing badge on it. The keymap has had both directions for a
while; the slash side did not, and the asymmetry was invisible because
both existing tests passed.

Added in the same pass, and each of them failed first:

- Every command in the table appears in the help. Caught `/help` itself
  being dropped from the help while the help was being restructured.
- Every command has a Chinese alias. Caught `ask` and `question` still
  being table entries rather than aliases.
- The first alias declared for a command is the one offered for it.
  Caught `提问` displacing `发送` in completion, because the registration
  built its list with `push`.
- Asking the model gets you out of shell mode, by prefix and by name.
  This is the reported bug, held in place.
- Typing survives the prompt being rewritten, because the prompt is
  redrawn in a live input area that may not be empty.

## Consequences

`chat-ui--command-repeatable-p` is now derived from `:default` rather
than a property of its own. `chat-transcript-channel-labels` defaults to
nil, meaning "use the localized label", so customizing one channel no
longer means restating the rest.

The `asking` indicator is found by text property rather than by searching
for its own text. It was searched for as an English literal, which would
have quietly stopped finding it in any other language and left the note
on screen underneath the answer.

`/goal` is still not implemented. It was asked for in the same list as
`/new`, `/save` and `/clear`, but unlike those it has nothing underneath
it, and a standing objective is not a command with a handler — it needs
its own design before it gets a name.
