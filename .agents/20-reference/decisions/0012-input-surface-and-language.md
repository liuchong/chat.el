# 0012 — The input surface, and language

Status: accepted
Date: 2026-08-26

## Context

Six things reported from actually using the surface. Five were bugs and
one was the reason the other five went unnoticed: there was no way to type
`/help`.

They are worth recording together because they share a cause. Every one
of them is on the path a person takes in their first minute — type a
slash to see what exists, press TAB, press `C-a` to fix a typo, run `ls`,
read the output, ask for help. None of that path was covered by a test,
and most of it did not work.

## What was wrong

**`C-a` landed before the prompt.** The prompt is buffer text, so the
line does begin there. It is not a cosmetic problem: at that position
typing inserts outside the input area and `C-k` takes the prompt with it.

**A leading `/` completed directories.** `chat-ui--path-token-p` accepted
anything starting with `/`, and an absolute path is the correct reading of
that character everywhere except the one place it means a command. So
asking to see the command list answered with the contents of `/`.

**TAB was not bound at all.** Two completion tables existed and the only
way to reach either was `M-x completion-at-point`. The help now claims TAB
completes, which it did not.

**`S-RET` was documented and `<S-return>` was bound.** They are different
events — `[33554445]` against `[S-return]` — so in a terminal there was no
way to type a second line. `C-j` was bound to nothing either, which is
what a terminal that can send neither would use.

**`ls` output was ragged.** BSD `ls -C` pads columns with tabs and counts
on stops every eight columns. Spacemacs sets `tab-width` to 4. `ls -l`
looked fine because it pads with spaces.

**`/help` was not a command.** It fell through to the model as ordinary
text and came back as a tool error, which is the worst possible answer to
"I don't know how to use this."

## Decisions

### The input area is a place, not just the end of the buffer

`chat-ui-beginning-of-input` goes to the input start when point is on the
prompt line and to the line start when it is on a continuation line
inside a multi-line message. Bound to `C-a` and `<home>`.

### A leading slash is a command until it cannot be

`chat-ui--command-token-bounds` claims a token only when it starts at the
input marker and has no second slash. `/cmd` is a command, `/Users/liu` is
a path, and `look at /` is a path. The ambiguity resolves as soon as there
is enough to resolve it, and the path completion asks the same question so
the two can never both fire.

Completion starts after the slash, so the candidates are the command names
themselves rather than names with a slash glued on.

### Shell output is decorated where it is displayed, not where it is produced

Tabs are expanded against a tab stop of 8 — the width that produced them
— rather than the buffer's `tab-width`. Fighting the buffer's setting
would mean overriding a user preference to fix output that is not even
always present.

Expansion counts columns with `string-width`, so CJK output lands where
the shell meant it to, and it copies text in runs rather than character by
character, because the colour applied just before it is a text property
and rebuilding from characters throws it away.

SGR escapes become faces. `ansi-color-apply` marks colour with
`font-lock-face`, which the display honours only where Font Lock is on, so
it is promoted to `face` — otherwise the colour is applied and invisible.
The base face is appended rather than set, so it sits under whatever
colour the output asked for.

Fixed pitch, because column alignment means nothing in a proportional font
however carefully the tabs were expanded.

### Language: read in yours, type in ASCII

`chat-i18n` is an alist of catalogs, resolved per lookup. No gettext: it
would buy a build step and a catalog format nobody here can read, for a
handful of strings.

The English text lives at the call site as the second argument, so the
source stays readable, an untranslated key still says something, and a
reviewer has the original next to the translation.

What is translated is what a person reads to learn the surface: the help,
and the feedback from commands they type. Not log lines, not tool errors,
not model prompts — the model answers in the user's language regardless.
`chat-i18n-coverage` reports the gap as a number so it is not a feeling.

English is complete by definition, since its text is at the call sites. A
report saying English is 0% translated would be saying nothing reads as
English, which is backwards.

Keys, command names and slash names stay ASCII. They are what you type.

## Consequences

The help extraction in the tests used to match only `C-c ...` sequences,
which is why `RET`, `C-g`, `TAB` and `S-RET` were never checked against
the keymap in either direction. Broadening it immediately found `TAB`
unbound and `S-RET` bound to a different event than the one documented —
two bugs the existing consistency test had been passing over.

A second key for a documented command no longer needs its own help line:
`<home>` beside `C-a` is findable through the command. Without that rule
the test would push every alias into the help and make it longer to read,
which is the opposite of the point.

Any shipped translation of the help must name exactly the keys and slash
commands the English one does. Checked against the English text rather
than a list, so it cannot go stale — and probed by deleting a key from the
translation to confirm it fails.

## Not done

The status line still says `Model:` and `auto:` in English. They are
short, they are next to identifiers that stay ASCII anyway, and localizing
half a line reads worse than leaving it. Reconsider if a catalog other
than Chinese arrives.

Tool output, approval prompts and error text from the tool layer are not
localized. That is the larger half of the strings, and most of it is
either an identifier or text produced by a subprocess.
