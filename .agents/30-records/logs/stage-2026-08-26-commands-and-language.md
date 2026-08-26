# Stage — naming the commands, deferred send, full localization

2026-08-26. 861 tests, all passing. Byte-compile clean.

## What prompted it

A report with four items, which turned out to be one item.

`/auto` was said to be broken: after one `!ls`, `pwd` still ran as a shell
command, an explicit `?question` worked but changed nothing, and the line
after it went to the shell again. Reproduced exactly.

It was working as designed, and the design was wrong. Decision 0011 had
declared only `/cmd` repeatable, with a correct reason — `/ask` does not
record, so sticky it would silently stop writing the conversation down —
and an incorrect conclusion. The same note justified itself by saying
asking the model "is already what plain input does", which is a statement
that the main behaviour of the surface has no name, written down without
noticing.

The other three items were the same problem seen from other angles.
`/ask` and `/question` differed in nothing; they were separate table
entries sharing a handler, and with `/?` and `?text` that made four names
for the ephemeral aside and none for the recorded conversation. `/help`
listed nine commands that did not exist and none of those four that did.

## What changed

`/send` names the recorded multi-step path. `/quick` is the ephemeral
one-shot, matching the `Assistant (quick)` label it was already drawn
under. `/ask` and `/question` are deleted: they were first pointed at
`/send`, since "ask the model" is what a reader means by them, and that
was not enough — both read equally well as either command, so either way
the reader had to remember which. `/?` and `/!` stayed as aliases, because
punctuation cannot be mistaken for a word that means something slightly
different, so the table is one entry per command and every other spelling
goes through the same mechanism that carries `/自动`.

Auto has three effects instead of a boolean: `sticky` claims plain input,
`reset` hands it back, nil leaves it. The baseline is `/send`, so there is
somewhere to return to, and anything that asks the model returns there.
The input prompt shows the holder as `cmd> ` — the status line said so
already and it was not enough, being at the top of a buffer that scrolls.

`/new`, `/list`, `/save` and `/clear` are implemented; their underlying
functions already existed. `/queue`, `/flush` and `/drop` collect notes
and send them as one numbered message.

Localization went from the help text to the whole surface: command names,
role labels, fold rows, status line, every message. Two further switches
cover what the model is told — `chat-reply-language` for the language of
the answer, `chat-prompt-language` for the language of the instructions —
with contracts never translated at either setting.

## What went wrong on the way

Every new consistency test failed on its first run, which is the only
reason to trust them.

The reverse slash-command test caught four undocumented commands, then
caught `/help` being dropped from the help while I restructured it. The
alias-coverage test caught `ask` and `question` still being table entries.
The alias-ordering test caught `提问` displacing `发送` in completion,
because registration built its list with `push` and turned declaration
order into reverse order.

Two things were fixed before they could fail. The "asking the model"
indicator was removed by searching the buffer for its own English text,
which translation would have broken silently; it is found by text property
now. And a duplicate `chat-transcript-channel-label` was defined — the
later definition won, so the localized one would have been dead code with
nothing to indicate it.

## What guards it

Both directions of the slash-command/help agreement, matching the keymap
tests, which had had both for a while while the slash side had one. Plus:
the reported bug held in place by prefix and by name; the input prompt
keeping its marker and the user's half-typed line when rewritten; the
queue surviving a JSON round trip as a vector; aliases neither shadowing a
command nor containing whitespace; prompt contracts surviving a Chinese
prompt language; a customized prompt winning over its translation.

## Not done

`/goal` was in the same list as `/new` and `/save` but has nothing
underneath it, and a standing objective is not a command with a handler.
It needs its own design before it gets a name.

`chat-prompt-language` defaults to following the interface language, as
asked. Whether a Chinese prompt makes a model behave better cannot be
measured from here; the fallback is per key, so an untranslated prompt
stays English rather than the whole set dropping back.
