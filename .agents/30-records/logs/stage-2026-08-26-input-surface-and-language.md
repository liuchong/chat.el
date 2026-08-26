# Stage — The input surface, and language (2026-08-26)

## What prompted it

Six problems reported from using the surface. Five were bugs, and the
sixth was why the other five had gone unnoticed: `/help` was not a
command, so there was no way to ask what existed.

Every one of them is on the path a person takes in their first minute —
type a slash to see the commands, press TAB, press `C-a` to fix a typo,
run `ls`, read the output, ask for help. None of it was covered by a test,
and most of it did not work.

## What changed

`C-a` and `<home>` go to the start of what you typed rather than to the
start of the line, which was before the prompt — a position where typing
inserts outside the input area and `C-k` takes the prompt with it. On a
continuation line inside a multi-line message the line start is still what
is wanted.

A `/` opening the input area now completes commands. It used to reach the
path completion, which read it as an absolute path and answered a request
for the command list with the contents of the root directory. The rule is
positional: a token at the input marker with no second slash is a command,
so `/cmd` completes commands, `/Users/liu` is a path, and `look at /` is a
path. Both completion functions ask the same question, so neither can
claim the other's token.

TAB is bound. Two completion tables existed and neither had a key.

Shell output is aligned and coloured where it is displayed. `ls -C` pads
columns with tabs and assumes stops every eight; Spacemacs sets
`tab-width` to 4, which is why `ls` was ragged and `ls -l` was not. Tabs
are expanded against the width that produced them, counting columns with
`string-width` so CJK output lands correctly. SGR escapes become faces
rather than literal `ESC[0m` noise. The command line itself is faced, so
it stands out from its own output.

`/help` exists, takes an optional topic that filters the help to the lines
mentioning it, and runs while a response is in flight — being stuck is not
less true while the model is talking.

`lisp/core/chat-i18n.el` resolves language from `chat-language`, then the
Emacs language environment, then the locale variables. English text lives
at the call sites as the fallback argument, so an untranslated key reads
as English rather than as nothing and a reviewer sees the original beside
the translation. Simplified Chinese ships complete in
`lisp/core/chat-i18n-zh-cn.el`, the help text being the reason the file
exists. Keys, command names and slash names stay ASCII: they are what you
type, not what you read.

## What went wrong on the way

Two bugs the existing consistency test had been passing over, found by
broadening it rather than by reading the code. `S-RET` was documented and
`<S-return>` was bound — different events, `[33554445]` against
`[S-return]` — so a terminal had no way to insert a newline. And TAB was
documented after this stage added the line, and bound to nothing. The help
extraction had only ever matched `C-c ...` sequences, so every unprefixed
key was unchecked in both directions. When a consistency test has a blind
spot, the bugs collect inside it.

ANSI colour was converted correctly and stayed invisible:
`ansi-color-apply` marks colour with `font-lock-face`, which the display
honours only where Font Lock is on. It is promoted to `face` now.

The first tab expansion measured a second tab against the original text
rather than the expanded output, so a line with two tabs came out wrong.
The second attempt rebuilt the string character by character and threw
away the colour properties applied just before it. The third copies runs
and counts columns on the output.

`run-tests.el` calls `ert-run-tests-batch-and-exit` itself, so
`--eval '(ert-run-tests-batch-and-exit "selector")'` runs the whole suite
and silently ignores the selector. Several runs in this stage were
full-suite runs that looked narrow.

The first attempt to probe the translation check deleted `C-c C-d` from
the Chinese help and the test still passed — because that key also appears
in the prose of the same file. Re-probed with a key that appears once, and
it failed as intended.

## What guards it

828 tests, all passing, and a clean byte-compile.

New coverage: three for input-area movement, four for command against
path completion, five for tab expansion and colour, four for `/help`, and
seventeen for the language layer. The translation tests require the
Chinese help to name exactly the keys and slash commands the English one
does, checked against the English text rather than a list so it cannot go
stale, and require the shipped Chinese catalog to have an entry for every
key any catalog defines.

The suite pins `chat-language` to `en`, since its assertions are written
in English; a test that cares about translation sets it itself.

Alignment and colour were checked against real `ls -C` output rather than
only in assertions, and the Chinese session was walked end to end.

## Result

Typing `/` lists the commands, TAB completes them, `C-a` lands on your
text, `ls` columns line up, colour comes through, `/help` answers, and
setting `chat-language` to `zh-CN` puts all of it in Chinese.
