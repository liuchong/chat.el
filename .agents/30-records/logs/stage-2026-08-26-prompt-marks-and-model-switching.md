# Stage: A Prompt That Names What It Will Reach

- Type: log
- Attention: record
- Status: done
- Scope: project
- Date: 2026-08-26
- Tags: prompt, marks, provider, model, mouse, i18n

## What Was Asked

Give each mode a mark in the prompt -- the assistant a star, as the
desktop client draws it, and the shell one of its own -- and, where the
configuration allows, show the current provider's mark and model name
there too, with a click opening a menu to switch when more than one is
configured. The stated reasons were that it looks professional, that it
raises the reader's confidence, and that it is genuinely more convenient.

## What The Prompt Is For

The prompt already answers one half of "what will RET do": which command
holds the line. It did not answer the other half. An unclaimed line goes
to a provider, and which provider was only ever stated in the status
line at the top of a buffer that scrolls, while the cursor is at the
bottom. That is the same distance that made the `cmd> ` prompt necessary
in the first place -- a shell that looks like a chat box is how a
question gets run as a command, and a window that looks like one provider
is how a question reaches another.

So the marks are not decoration with a rationale bolted on. A glyph is
worth having exactly when it is read faster than the word it replaces,
and the prompt is read at every keystroke.

## Decisions

**No emoji, no icon font.** Emoji are double-width, depend on a colour
font, and differ per platform, so they neither line up in a monospaced
buffer nor take a face. Icon fonts need the reader to have installed a
patched font, and a font that is installed but missing a code point
cannot be detected. Single-column Dingbats can be coloured by face,
which is required: a brand colour has to follow the background from
light to dark.

**The provider's mark replaces the generic star, rather than following
it.** Two glyphs saying "this is an assistant" is one too many. This is
also what termini-desktop does -- `sparkles` appears only when no tool is
selected.

**A mark is dropped when the frame cannot draw it.** `char-displayable-p`
decides, and the prompt degrades to what it was before marks existed. A
hollow box carries nothing, takes a column anyway, and reads as a broken
program.

**Four providers get a character, everyone else gets an initial.**
Anthropic's starburst, x.ai's X, OpenAI's knot and Gemini's four-pointed
star have widely available equivalents that genuinely resemble them.
Inventing symbols for the rest would be filling rows rather than
informing anyone, so they get the initial of their display name --
`DeepSeek` and `Doubao` both being `D` is acceptable, because the model
name and the colour sit right there.

**Brand colours are only used for brands.** Kimi, Claude and DeepSeek
have known ones, each with a light and a dark value; the rest inherit the
surrounding text. A test walks the tree and fails if any file outside
`chat-mark.el` mentions a brand face, because using a trademark colour
for our own interface would be claiming it.

**The prompt names the model, not the provider symbol.** What is shown is
`(plist-get config :model)` -- the field the request carries. A prompt
that names something other than what is about to be used has stopped
preventing mistakes and started causing them. Long names truncate by
column width, so a CJK name is not measured at half its width, and the
full value is on hover.

**The shell line does not name a model.** RET there does not reach one.
Showing a fact that is irrelevant at that moment trains the eye to skip
the place it is shown.

**Clicking goes through `chat-set-model`.** It already refuses while a
response is in flight and already persists the change; a second path
would be a second chance to forget both. The affordance appears only
when there is more than one provider, since a `mouse-face` over a menu
of one promises a choice that does not exist, and a popup menu is only
attempted when `display-popup-menus-p` says so -- Emacs in a terminal
falls back to `completing-read` rather than losing the feature. The
keyboard route was already there and stays: a mouse-only operation is,
in Emacs, no operation.

## Also Fixed

Two empty directories, `one` and `two`, had been appearing in the
repository root. `chat-test-with-temp-dir` does not rebind
`default-directory`, so the `cd -` tests written in an earlier stage were
creating them wherever the runner started. The tests passed either way,
which is why nothing pointed at it. They now name `temp-dir` explicitly.

## Verification

1044 tests pass, 23 new. The pure table is tested on its own: every glyph
one column wide and inside the basic plane, an undisplayable glyph
refused, the four listed providers, the initial fallback, the star
fallback, both backgrounds present on every brand face, and the static
check that no other file borrows one.

On the prompt: the model named is the one the config carries; a shell line
carries the shell mark and no model; queue carries its own; an unmarked
command still gets a prompt; an undisplayable frame yields exactly the old
prompt; a long CJK name truncates by column with the full value on hover;
the click affordance appears only with a choice and does not leak into the
input; the mark is as protected and as recoverable as the rest of the
prompt; switching goes through the command that checks, is refused
mid-response, and leaves the prompt naming the new model.
