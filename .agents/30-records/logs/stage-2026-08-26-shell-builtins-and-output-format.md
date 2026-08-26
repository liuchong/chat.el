# Stage: Shell Builtins, Completion Restraint, And The Output Format Question

- Type: log
- Attention: record
- Status: done
- Scope: project
- Date: 2026-08-26
- Tags: shell, completion, markdown, mdp, prompt, specs

## What Was Asked

Two small complaints and one design question.

The complaints: a completion dropdown arrives while typing a command, and
because a completion UI takes RET, the key that sends a message becomes
the key that picks a candidate — the message needs a second RET, and the
popup moves the buffer around. And `cd -` reports `Directory not found: -`
where a shell would go back; more generally, `cmd` mode should support the
capabilities a shell is expected to have.

The question: what output format should the system prompt ask the model
for. Markdown is confirmed as the direction, and it is to be stated in the
prompt rather than left to habit. Hiding syntax markers is approved, and
the display is to be built in Emacs rather than delegated to an external
renderer producing a browser-style preview — the wanted result is an
Org-like presentation of Markdown syntax. Also: whether MDP, the
platform's own protocol, can be supported.

## The Boundary That Decided The Shell Work

A subprocess cannot move its parent's working directory or set its
parent's environment. That single fact is the whole reason any command
has to be interpreted in Lisp instead of being handed to a real shell, and
it is a sharp enough line to name the file after: a builtin belongs in
`lisp/ui/chat-shell-builtins.el` if and only if its effect must outlive
the command that issued it. `cd`, `pushd`, `popd`, `dirs`, `export` and
`unset` qualify. `ls` does not, and neither does anything else — the shell
is better at those than we will ever be, and reimplementing them would
mean maintaining a worse shell inside a chat client.

Before this, `cd` was special-cased inline with a comment explaining the
same fact, and nothing else was. `export` went to the shell, where it set
a variable in one subshell and was gone by the next line: the variable
appeared to be set and then was not, which is worse than declining to set
it.

## Why `cd -` Failed

`chat-ui--directory-command-target` parsed the argument and handed it to
`chat-ui--change-directory`, which called `expand-file-name`. For `-` that
yields a relative path named `-` under the current directory, which is not
a directory, so the missing-directory branch fired. Nothing was tracking a
previous directory at all — there was no OLDPWD equivalent, so there was
nothing for the dash to mean.

The previous directory is now recorded before each move, inside
`chat-ui--change-directory`, so every path that changes directory feeds it
rather than only the one that reads it. Two `cd -` in a row swap back and
forth, as in a shell. With no previous directory the command says so
instead of inventing a path.

## Why The Popup Had To Go, Not Be Coordinated With

The tempting fix is to make RET notice an open completion session and send
anyway. That does not work: Corfu, Company and `completion-in-region-mode`
bind RET in their own keymaps, which override the major mode map, so
`chat-ui-send-message` is never called and has nothing to notice.

The problem was not the completion UI, it was that chat.el opened it
uninvited. `chat-mode` added a buffer-local `post-self-insert-hook` that
called `completion-at-point` on path-like tokens, with
`chat-ui-auto-path-completion` defaulting to `t`. Turning that default off
removes the whole class of problem, and costs nothing: TAB is bound to
`completion-at-point`, which fills the common prefix on the first press
and lists candidates on the second — what a shell does. The option stays
for anyone who wants the popup back.

The existing test asserting the auto-trigger only fires on path-like
tokens now binds the option on, since the narrowing still has to hold for
whoever turns it back on.

## Markdown: Confirmed As Format, And The Display Is The Real Work

The format question answers itself. Every model is trained to organize
answers as Markdown, so any other format has to be wrung out of the model
against its training distribution, and it will not hold. What was missing
is that the system prompt said nothing about format at all — grep found
no output-format instruction anywhere in
`chat-tool-caller-build-system-prompt`. Markdown was working by habit.

`chat-tool-caller--output-format-note` now sits beside the reply-language
note, on the same footing: both say how to answer rather than what, and
both apply whether or not tools exist. It asks for Markdown and narrows it
to what a buffer displays well, and every restriction carries its reason,
because a prompt rule without one reads as optional and gets dropped as
soon as the content makes it inconvenient. ATX headings from level two,
because setext cannot be recognised until the line after it, by which
point it is drawn, and because a level-one heading competes with the role
labels. No hand-wrapped paragraphs, because text is wrapped to the window
and a hand-wrapped paragraph is ragged at every other width. A language on
every fence, because the language is what selects highlighting.

The display side is where the work actually is, and the audit was worse
than expected. There is no Markdown engine: closed ` ``` ` fences get one
constant face on every insert, and at finalize only, ATX lines and
`**bold**` get faces that the next redraw drops on the floor. Markers are
all visible, so the screen shows source rather than a document. The
language tag is parsed and used to pick between two faces, never to find a
major mode, so every language is one colour. `word-wrap` is unset, so long
prose breaks mid-word. Two identically-defined code-block faces split the
same surface between the insert path and the finalize path.

Spec 005 records the engine. The governing decision is one renderer as a
pure function of the source, with every path rendering from the session
record and never from already-rendered buffer text — that is the
structural answer to two paths producing different styles, rather than
asking two paths to remember to call the same function. The means are
Emacs means: `invisible` for markers, which is required rather than
preferred because it keeps the characters in the buffer, so copying yields
the original Markdown; `display` for bullets and rules, which does not
change buffer text either; real major modes in a temp buffer for code, with
`delay-mode-hooks`, a `condition-case` fallback, and an explicit language
mapping table, because `(intern (concat lang "-mode"))` would let model
output decide which packages load; `string-width` for table columns,
because CJK is double-width and `length` misaligns every table containing
Chinese. `visual-line-mode` is ruled out — it rebinds `C-a`, which
`chat-ui-beginning-of-input` owns.

## MDP: Adopted Where It Is Strong, Declined Where It Is Not

MDP is a converged subset of Markdown that parses exactly three
constructs — two levels of ATX heading, `- key: value` lists, and pipe
tables — and treats everything else as comment with zero effect on the
result. Its central claim is one text with two readings: machines read the
whitelist, humans and models read all of it.

That claim holds here. A transcript is read by a program, a person and the
model's next turn, and today those three are served by one JSON blob that
suits only the first. And because an MDP document is valid Markdown, spec
005 renders it for free — no second display path.

The comment rule is the concrete win, and there is evidence for it in the
tree. `chat-tool-caller--fix-broken-json` is a pile of empirical repairs:
strip a stray leading `json`, strip fences, rewrite `"_call"` back to
`"function_call"`. A protocol needing that function is a protocol that
does not hold in a model's hands. Prose around structure is the habit
causing it, and MDP defines prose as ignorable rather than tolerating it —
its §7 says the whitelist's complement is never an error, that there is no
third state called a syntax error.

But MDP does not solve the half that hurts most, and the spec says so
plainly. Its §5.2 makes values single-line: a multi-line string needs
`\n`-escaped quoting, which is the same escaping problem JSON has. The
arguments that break are exactly the multi-line ones — patches, file
contents — and chat.el already has a better answer for those in the
`*** Begin Patch` sentinel, where content is verbatim and nothing is
escaped. So spec 006 adopts MDP for the text tool-call protocol and for
structured tool results, keeps the sentinel envelope for multi-line
payloads, and leaves provider-native function calling and the JSONL
session record alone: the first is a wire format the API decides, and the
second is machine-only, where changing format buys nothing and risks the
record.

Two constraints are written in because they are how this stays cheap.
chat.el implements the specification and does not depend on the mdp
repository's implementation, so a moving spec costs a parser change and
nothing else — worth stating because that repository labels itself v0.0.1
and `MDP/1.0 Stable` in the same header. And the MDP path may not acquire
an equivalent of `--fix-broken-json`: its only tolerance comes from the
comment rule, or the document is non-conforming and should be reported
with an error code and a line number rather than guessed at.

## Verification

1009 tests pass, up from 984. New coverage: sixteen tests over the shell
builtins, five over the UI behaviour of `cd -`, `pushd`/`popd` and export
persistence, one asserting completion does not arrive uninvited while TAB
still completes, and three over the output-format prompt — that it asks
for Markdown, that each restriction and each reason is present, and that
it is stated whether or not tools exist.

## Two Alignments That Changed The Specs

Both specs were corrected after review, and the second correction was a
structural error rather than a wording one.

**Format and display are two layers.** Markdown the format owns
full-document input and output: it is what the model writes, what the
session record stores, what leaves the buffer on a copy, and what goes
back to the model next turn. It is the single source of truth.
`chat-markdown.el` owns only its display in Emacs. The consequence worth
stating as a constraint is that a rendering never flows back as data —
buffer styling is a view of the document, not the document. Spec 005's
pure-function rule and its insistence that hiding be reversible are both
consequences of that, not independent preferences.

**MDP is a data transport protocol with JSON's standing, not a document
tool.** Its readability is a property, not its purpose; JSON pretty-prints
too and nobody calls JSON a document format. Spec 006 had the positioning
right in prose and then contradicted it in Requirement 4, which said MDP
payloads must have no display logic of their own and must go through spec
005. That would make `lisp/core/chat-mdp.el` depend on
`lisp/core/chat-markdown.el` to display anything, tying a protocol
module's usability to a display layer, and — as originally written, with
the renderer in `lisp/ui/` — inverting the repository's dependency
direction, which is strictly ui → core with no core module requiring
`chat-ui` anywhere.

The fix came from MDP's own claim, one text with two readings. Two
readings means two views with two owners. The document view belongs to
spec 005, free because an MDP payload is valid Markdown, and `chat-mdp.el`
may not compete: no marker hiding, no code fontification, no bullet
substitution, no link folding. The machine view belongs to `chat-mdp.el`,
and it is the half spec 005 structurally cannot do, because it sees only
Markdown syntax and has no parse result — it cannot know which line is
structure and which is comment, or that `- age: 28` holds the number 28.
That view is not a debugging extra: whether the two readings agree cannot
be judged without seeing the machine one.

The renderer moved to `lisp/core/chat-markdown.el` as part of this. The
precedent is `lisp/core/chat-transcript.el`, which also defines faces and
decides typography and sits in core because it is pure — it computes
styling and never touches a buffer or a window. With both modules in core,
`chat-mdp.el` can share the width-aware column layout without inverting
anything, and that layout must have exactly one implementation: a Chinese
table aligned in one view and ragged in the other is harder to find than
one that is ragged in both.

`chat-mdp.el` is therefore a codec first. Its irreplaceable job is MDP
text to and from an Elisp representation, and the representation is now
pinned down because `nil` in Elisp is falsehood, the empty list and the
empty value all at once, while MDP's `false`, `[]` and `null` are three
distinct values — using `nil` for any of them makes the round trip lossy.

## MDS

Considered and deferred, and the deferral costs nothing, which is the only
reason a deferral needs. MDS's own specification says core parsers do not
know it exists and that validation is an independent layer above parsing,
so it can be added later without touching the codec.

Three reasons not now: it is a draft that explicitly permits breaking
changes while MDP claims stability; we already express schemas in the tool
registry's parameter declarations, and two schemas would diverge for the
same reason two renderers would; and it belongs after the payload layer is
proven on the tool-call path rather than before.

One candidate use is recorded so the reasoning need not be redone:
emitting MDS from the tool registry, so the schema the model reads and the
payload it writes share one syntax. The value there is in the emitter, not
the validator — parameter checking already exists. One constraint holds
now to keep that door open: the parser does only MDP's four line types and
never guesses at dates, enums or amounts, because semantic inference in
the parser would fight the schema layer over whether `2026-07-21` is a
string or a date. And no hooks are pre-placed for MDS, since the spec
already guarantees separability and a reserved hook would take on the
coupling early for nothing.

## What Is Left

Specs 005 and 006 are specifications, not implementations. Neither
`lisp/core/chat-markdown.el` nor `lisp/core/chat-mdp.el` exists yet, and
005 comes first because 006 depends on it for the document view and for
the shared column layout. Two documentation inconsistencies found during
the audit are recorded in spec 005's acceptance list rather than fixed
here: `docs/index.html:104` claims header and emphasis styling follows
differential streaming when it runs once at finalize, and
`docs/architecture/design.md:711` lists `chat-markdown.el` as though it
were present.
