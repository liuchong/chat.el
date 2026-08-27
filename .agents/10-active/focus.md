# Focus

- Type: progress
- Attention: active
- Status: active
- Scope: current-stage
- Tags: focus, current, stage

## Doing Now

There is one chat surface. Code capability is a property of a session,
not a second display: `chat-code-mode` is gone, and a coding session is a
`chat-mode` buffer whose metadata carries a project root, a focus file
and a context strategy. Decision 0009 records why and how it was staged.

The duplication is gone with it. 1712 lines left `lisp/code/chat-code.el`
and 475 arrived in `lisp/ui/chat-ui.el`, the difference being the copies
themselves. Both sides' better behaviour survived: fence-safe streaming
and tool summaries by kind from the code side, buffer-liveness guards,
project instructions and both budgets from the chat side.

Two invariants are now asserted rather than reviewed. The keymap and
`chat-commands-help` agree key by key in both directions, which is what
would have caught the `C-c C-a` collision — accept-edit against
auto-approval — before the maps were merged. And `test-docs.el` requires
every `M-x` name in the docs to be a command, which found nine dead
names.

Both budgets are in place: steps in `lisp/agent/chat-agent-budget.el`,
context in `lisp/core/chat-context-budget.el` with per-category
allowances and a declared-residency parser beside it. The typed
transcript model and the request projection are in place too.

Storage and self-knowledge landed on top: `chat-session-log.el` tells a
run where its own transcript is and filters it back by turn, category,
work and time; `chat-scratch.el` gives each session pruned scratch space;
`chat-knowledge.el` keeps a global note store whose index — not its
bodies — rides in the prompt.

The input command layer landed earlier: chat input parses through
`lisp/core/chat-command.el` and dispatches through `chat-ui--command-table`,
with shell execution, history repeat, the session working directory,
ephemeral queries and a literal escape.

The display now draws that record instead of keeping its own copy.
Committed history is redrawn from `chat-session-messages`; a live tail
holds only what has arrived and not been recorded; `message-appended`
hands one to the other, which is what keeps an intermediate step on
screen. Reasoning and tool work fold behind a summary row, interim prose
is italic, the answer is ordinary text and never folds. Decision 0010
records the shape and what it replaced.

The commands have names that mean what they say. `/send` is the recorded
multi-step conversation, which until now was the one behaviour on the
surface with no name; `/quick` is the ephemeral aside it was being
confused with. `/?` and `/!` are aliases through one mechanism, so the
table is one entry per command; `/ask` and `/question` are gone rather
than reassigned, because both read equally well as either way of asking.
Decision 0013 records why four names had accumulated for the aside and
none for the conversation.

Auto returns to a command rather than to a cleared variable. Commands
declare `:default sticky` or `:default reset`; the baseline is `/send`,
and anything that asks the model releases the claim -- which is the bug
that was reported, a session staying a shell after one `!ls` with no
question able to get it out. The holder shows in the input prompt as
`cmd> `, not only in a status line at the top of a scrolling buffer.

`/new`, `/list`, `/save` and `/clear` are implemented. `/queue`, `/flush`
and `/drop` collect notes and send them as one numbered message, on the
session so they survive a reopen.

Slash commands have the consistency guarantee the keymap got, now in both
directions. The one-way version passed while four live commands were
undocumented; both directions failed on their first run, the second
catching `/help` being dropped from the help while it was restructured.

Six problems reported from real use are fixed, and five of them were on
the path a person takes in their first minute: `C-a` landing before the
prompt, a leading `/` completing directories instead of commands, TAB
bound to nothing, `ls` columns ragged because `ls -C` pads with tabs
against stops of 8, and `/help` not being a command at all. Broadening the
help-key extraction to unprefixed keys found two more the old consistency
test had been passing over: `S-RET` documented while `<S-return>` was
bound, and TAB unbound. Decision 0012 records it.

Language covers the surface, not just the help. `chat-i18n` resolves from
`chat-language`, the Emacs language environment, then the locale, with
English at the call sites as the fallback. Command names have aliases, so
`/auto` and `/自动` are one entry; completion offers the language in use and
any language's names are accepted. Role labels, fold rows, status line and
messages are localized. Two further switches cover what the model is
told: `chat-reply-language` for the answer, `chat-prompt-language` for the
instructions, with JSON keys, tool names and patch envelopes never
translated at either.

Three defects reported from real use were fixed after that, and two of
them had been silently corrupting data. A tool call id is now answered by
one function, so the assistant `tool_calls` entry and the `tool_call_id`
of its result cannot disagree; two fallbacks that did disagree — one
keyed on the tool name, one on the position — made any session containing
an id-less turn unsendable, which is how it was found. The session loader
no longer wraps `parse-time-string` in `decode-time`, which had dated
every reopened message to 1970 and written it back; dates already on disk
are lost. And fullwidth normalization is a Unicode range rather than a
punctuation table, with its boundary drawn by ownership: chat.el folds
what it interprets and leaves what it forwards, so `！` folds and the `ls`
after it does not. Decision 0014 records that rule, and AGENTS.md carries
it forward so it binds the next normalization rather than only this one.

The wiki is a feature rather than 887 lines nothing could reach. One
`/wiki` with subcommands replaced five `/wiki-*` names that had no
handler; the subcommand folds from fullwidth and takes a localized alias
while its argument does not, which is decision 0014 one level down. The
model reaches it through tools rather than a prompt index, because a wiki
grows without bound and `chat-knowledge.el`'s arrangement would put that
growth in the fixed region of the context. Ten defects came out with it,
most of them silent: frontmatter was matched with `.` and so never parsed
across lines, losing every title and date to a filename fallback; CJK
titles were slugified by deleting non-ASCII, which collided them all on
the empty string; the wikilink pattern used `[^\]]`, where a backslash is
not an escape, so link extraction returned nothing every time it ran and
the whole linking half of the wiki — backlinks, orphans, broken links —
had never worked; and `create-page` wrote caller-supplied bodies without
frontmatter, so every page the model writes arrived untitled. Loading the
file also wrote to disk whenever a `wiki` directory sat beside
`default-directory`, which in the test runner is this repository. Lint is
now one scan rather than quadratic in reads, and the five `M-x` wrappers
that duplicated subcommands are gone.

The four found last were found by running it end to end in Chinese, not by
the 42 tests written first — those passed because the test helper
hand-wrote the frontmatter that the real path failed to write. A helper
that constructs valid input by hand tests the reader and not the writer.
Decision 0015 records it.

The command prompt behaves like a shell where it did not, and the boundary
deciding what may is named: a builtin is interpreted in Lisp if and only
if its effect must outlive the command that issued it, because a
subprocess cannot move its parent's directory or set its parent's
environment. `lisp/ui/chat-shell-builtins.el` holds those six and nothing
else. `cd -` reached `expand-file-name`, which read the dash as a relative
path named `-`, and nothing was tracking a previous directory for it to
mean; `export` reached one subshell and was gone by the next line, so the
variable looked set and then was not.

Auto path completion is off. A completion UI that is open takes RET, so
the key that sends became the key that picks a candidate — and
coordinating with it is not possible, because Corfu and Company bind RET
in maps that override the major mode's, so `chat-ui-send-message` is never
called and has nothing to notice. Not opening it uninvited is the fix.
TAB still completes as a shell does.

Output format is stated instead of assumed. Nothing in the system prompt
had ever mentioned format; Markdown was working on the model's habit
alone. It is now asked for and narrowed to what a buffer displays well,
with a reason on every restriction, since a prompt rule without one reads
as optional.

Specs 005 and 006 are written and not implemented, and both were corrected
on review.

005 is the built-in Markdown display engine, at
`lisp/core/chat-markdown.el`: an Org-like result from Markdown syntax
using Emacs means only — `invisible` for markers so copying still yields
the source, real major modes for code behind an explicit language table so
model output cannot decide which packages load, `string-width` for table
columns because CJK is double-width. Its governing rule is one renderer as
a pure function of the source, the structural answer to the two paths that
style differently today. The division it now states outright: Markdown the
format owns full-document input and output and is the source of truth,
this module owns only its display, and a rendering never flows back as
data. It sits in core rather than ui on the precedent of
`chat-transcript.el` — pure, computes styling, never touches a buffer —
which is also what lets a core module reach it without inverting the
repository's strict ui → core direction.

006 judges MDP, which is a data transport protocol with JSON's standing
rather than a document tool; its readability is a property, not its
purpose. Adopted for the text tool-call protocol, where its comment rule
retires the empirical repairs in `chat-tool-caller--fix-broken-json`, and
for structured tool results, where one text serving a program, a person and
the next turn is exactly its design. Declined for multi-line payloads,
whose single-line values need the same escaping JSON does while the
existing patch envelope needs none.

`chat-mdp.el` is a codec first: MDP text to and from an Elisp
representation, pinned down because `nil` is falsehood, the empty list and
the empty value at once while MDP's `false`, `[]` and `null` are three
values. Its display role is bounded by the two-views rule — the document
view belongs to 005 and is free, the machine view belongs here because 005
has no parse result and so cannot tell structure from comment. MDS is
deferred at zero cost, since its own spec makes validation a separable
layer above parsing; the parser keeps to four line types so that stays
true.

The prompt now answers both halves of "what will RET do" (spec 007). It
already named the command holding the line; it did not name the provider
an unclaimed line reaches, and that was stated only in the status line at
the top of a buffer that scrolls while the cursor is at the bottom — the
same distance that made `cmd> ` necessary. So an unclaimed line carries
the provider's mark and the model the request will actually name, a shell
line carries a shell mark and no model, and `lisp/ui/chat-mark.el` holds
the tables as pure functions.

Three constraints shaped it. Marks are single-column BMP characters, not
emoji or icon-font glyphs, because only a face can follow the background
from light to dark and only a single column keeps a monospaced buffer in
step. A glyph the frame cannot draw is dropped rather than shown as a
box, so the prompt degrades to exactly what it was. And brand colours are
used for brands only — a static test fails if any file outside
`chat-mark.el` names one.

Clicking the model opens the menu and goes through `chat-set-model`,
which already refuses mid-response and already persists; the affordance
appears only when there is more than one model to pick, and a terminal
without popup menus falls back to `completing-read` rather than losing
the feature.

That menu then had to be about models rather than providers (spec 008).
The list was every registered vendor, sixteen of them, so it was narrowed
to the ones a key can be fetched for — and what remained still showed a
two-protocol vendor twice and none of its models, because a provider
symbol was answering three questions at once. Vendor, protocol and model
are now separate fields on a registration, each defaulting so that the
registrations without a variant say nothing new; the model name lives on
the session, nil meaning "the provider's default at request time" so that
a default changed in configuration still reaches sessions that never
pinned one. The protocol is deliberately not offered — "I want k3" is the
request, the wire format is not — but stays reachable by name.

Both real vendors answer `GET /models` with exactly the list now written
into their registrations, which makes discovery the obvious next layer;
it cannot be synchronous while a menu is being drawn, so the written list
is the fallback and `chat-llm-provider-models` is the one place that has
to change.

Sending still hitched after all that, and the cause was two things
neither of which was the milliseconds. `(redisplay)` does nothing when
input is pending and returns nil to say so, so of every paint in the
program the one placed to rescue the send was the one most liable to be
skipped; it is now `(redisplay t)`. And the same send measured 3ms once
and 400ms the next, with the blame landing on a different callee each
time — the signature of garbage collection, confirmed with `gcs-done` and
`gc-elapsed`. The allocation paying for it was repeated work: every send
re-read every applicable `AGENTS.md` and re-ran the resident partition
over 20–30KB. Caching the contents (not the search, which must still
notice a file added further up) halved allocation per send and took the
collections out of the sample: keystroke to paint 4.5ms → 1.5ms, one warm
send 5–13ms → 3.2–3.7ms, three collections over eight sends → none.

The conversation redraw was left alone deliberately. It is the largest
pre-paint term at 400 messages (17.9ms) but its contract — the record is
the only source, so append, fold and reopen all produce the same screen —
is what an append path beside it would break.

The forced paint is what fixed the reported hitch, confirmed from the
session where it happened rather than from a reproduction: 28ms from
keystroke to painted question. Getting there took three wrong guesses,
all of them made outside that session, and the lesson is recorded: the
costs that decide whether RET feels instant live in the display and in
the reader's own hooks, and neither exists in batch mode or in an
`emacs -Q`. So the send path now measures itself and logs one line —
phases in order, the pre-paint window separated out, plus buffer size,
message count, undo state and hook counts to explain an outlier.

The split marks then named two things across four real sends. The
pre-paint window is 28–33ms on every send including the first, so that
half is closed. What remained is after the paint, and the reader does
feel it: their question is on screen while the editor is dead, 1.17s on
the first send and ~290ms on each one after.

The 924ms that appeared once in `context` and then 29ms three times
running was a collection, not work — compaction on a copy of that exact
session is 28.6ms with one full save at 23.8ms. So phases now carry the
collections that happened inside them, `[gc N, Mms]`, which is what
separates doing expensive work from allocating past the threshold on
everyone else's behalf.

The clock moved from the UI into `chat-log` so the layers below can mark
their own phases: a clock at the door says the room is slow, not which
piece of furniture. `spawn` is deliberately separate, since forking is
the one cost that cannot be measured anywhere but the sender's Emacs.

Weighing those phases against the real session found three wastes on the
keystroke path. Every request printed its whole payload through `%S` — a
second formatting pass, a quarter-megabyte of `prin1`, appended to a
100MB log — which took `chat-llm--build-request` from 7.4ms to 0.7ms once
it logged the shape instead. `executable-find "curl"` ran per request at
11–15ms to answer an unchanging question. And the UI prepared a context
that the run prepares again before every step, compacting the same
history twice per send when a compaction rewrites the whole session file.

About 200ms of the per-send `start` is still unnamed: everything on that
path adds to ~60ms here, of which 30ms is now gone, and the remainder
does not exist on this machine. The phase marks will say whether it is
the fork. Deferring the work onto an idle timer was considered and
rejected for now — a timer blocks input just the same when it fires, so
it relocates the pause rather than removing it.

Asking why a stall lands on RET when RET has not sent anything yet is
what found the next thing. `gc-cons-threshold` counts bytes consed since
the last collection without regard to who consed them, so a send's chance
of being the one that crosses is its share of the threshold — and the
threshold is already 100MB, since Spacemacs sets it there. A send
allocated 12.4MB of that, so roughly one in eight, against one stall in
four timed sends.

Of that 12.4MB, 5.73MB was `chat-context-message-tokens`, and it was not
a performance finding. It counted the 120-character *snippet* of each
message's tool calls and results, the one a durable summary shows, while
the request carries both in full: 5,295 tokens counted for a payload of
about 63,000, 8.4x under. Auto-compaction therefore sat still on any
tool-heavy session because by its own arithmetic there was nothing to
compact. Counting the fields that go out, by `length`, made it 0.2ms and
0.09MB and made the count match. 1088 tests passed with it 8.4x wrong,
because every budget test built its own messages and none asserted the
count tracks the wire.

The other 5.19MB was the cold project-instructions read, which the cache
already reduces to once per Emacs. Per-send allocation is now ~1.6MB.

The streaming accumulator was the dominant allocator and no longer is.
`chat-agent-loop.el` rebuilt the whole reply per piece, so the log's
worst reply — 340 pieces, 321KB — cost 53.6MB to accumulate, 171 times
the text. Clojure would not have helped: its structure sharing is for
vectors and maps, and its strings are flat and immutable like Emacs's.
Pieces are now held in a list and folded into one string only when the
reply is published, and publishing backs off as the reply grows — every
piece while it is short, and past that once the unpublished tail reaches
an eighth of what is out. 340 handovers became 36, and 53.6MB became
3.3MB. Nothing is lost: the end of a run flushes whatever never reached
the threshold. The transport's reasoning accumulator had the same shape
and is read once, at the end, so it just pushes.

Backing off made the *drawing* worse, which is how the larger one was
found. `chat-ui--insert-formatted-response` searched a fresh copy of the
remaining text for each fenced block, and copied it twice, so drawing
cost length times block count: 320KB of prose and code allocated 986MB
and took 592ms — ten collection thresholds to draw one reply once.
`string-match` takes a start offset, which is both linear and more
correct, since `^` had been matching wherever the copy happened to begin.
1.74MB and 5ms, and flat at 0.5MB per 100k across four sizes.

Together, the log's worst reply went from 73.5MB and 689ms with five
collections to 5.9MB and 34ms with none. This is not the first send's
924ms, though: real sessions hold small messages — 41 of them, 19KB in
total, longest 8KB — so neither cost was ever on the keystroke path. What
they were doing was filling the threshold during a long reply, so the
collection landed on whatever allocated next. The first send after a
restart still pays for startup garbage that is not this program's.

Approval has an approver, and it is called what it is (spec 013). `auto`
was reported as not doing what its name said, and it was not: fast path
for grants, fixed rule list, refuse without asking -- `manual` with the
question suppressed, which costs the user their yes and buys no safety,
since the list is the same list. It is `guarded` now, with `auto` accepted
everywhere it is read and written nowhere, and under it
`lisp/core/chat-approval-guard.el` sends one neutral request per call that
reaches the mode branch. Its prompt is two parts, an immutable preamble
and rules the user may extend; its payload is facts and no narrative --
environment, arguments labelled untrusted, relative paths as written and
as resolved, and the gate's own objection as evidence. No history and
nothing from the executing model, because a guard carrying the run's
history stops answering "is this within policy" and starts answering "does
the assistant want this". An allow needs a decision, high confidence and a
named rule; everything else refuses, including a timeout and a missing
provider.

A verdict counts as a person's approval does, which is one `memq` in
`chat-approval-command-consent-p` and is the whole mechanism -- the gate
already objected and the guard ruled anyway, so a gate that refuses again
makes the verdict decoration. Its price is that a wrong verdict skips the
gate, which is what `chat-approval-guard-never-allow-p` bounds: writes
outside the boundary, deleting a home or a project root, rewriting
published history, a credential and the network in one command, and edits
to the approval records themselves, checked before any request and not
arguable. A refusal comes back as a tool result rather than an error and
says the policy refused rather than the user, so the run changes route
instead of retrying -- the eight-minute git incident, one layer up.

Two structural faults came out with it. Authorization happened separately
in the two execution paths, so a grant applied or did not depending on
whether a tool declared an `async-function`; it is one point now, before
the split, and the synchronous entry refuses under `guarded` rather than
quietly applying the rules the guard replaces. And the floor was silently
inert for its first hour, every predicate returning nil because command
parsing was reached through `fboundp` and the module was not loaded -- a
conditional dependency on the thing the floor is made of is not a
dependency.

Shadow running is built and ships off. It runs the guard alongside any
mode, decides nothing, and records the verdict against what actually
happened with the kind of reference noted, because a tired person's
fortieth allow is a noisy label. Under `guarded` it hands the decision
back to the rules, since shadow meaning one thing there and another under
`manual` would make the switch unreadable. Default-off has a stated cost:
samples come only from people who turn it on. Decision 0016 records the
lot.

The guard's structured request is now portable across thinking providers.
It offers the verdict tool with `tool_choice: auto`; the parser, confidence
check and fail-closed path enforce structure instead of relying on a forced
call that some providers reject. Its environment also follows the session
being judged for both working directory and project root, rather than
borrowing the root from whichever chat buffer happens to be current. The
credential-dependent check and rationale are recorded in
`stage-2026-08-27-the-guard-can-think.md`.

Guard policy now has the deterministic tuning layer its design called for:
literal whole-command allow and deny entries ahead of semantic judging,
with deny winning and no prefix expansion. Tool arguments that try to
instruct the adjudicator abstain locally. Every actual or shadow verdict is
also durable as an `approval-guard-review` event in that session's bounded
wire log, rather than existing only in Emacs memory until someone exports
it.

Code-capable prompts now lead with a separately configurable objective-task
section before persona and operational rules. It tells the agent to optimize
for objective completion rather than approval, refuse developer errors and
ambiguity rather than guess, perform no emotional labour, stop replying on
identified emotional breakdown, answer abuse directly, and keep output
strictly task-relevant. Decision 0018 supersedes decision 0017's earlier
non-retaliatory interaction stance while retaining the separate leading
section and its customization boundary.

Canonical suite: 1354 tests passing.

## Next Stage

Implement spec 005, then 006. Neither `lisp/core/chat-markdown.el` nor
`lisp/core/chat-mdp.el` exists yet; 005 comes first because 006 depends on
it for display and gets it for free.

Auto's second sense: an agent running rounds until its goal is met rather
than until it stops calling tools. The step budget already bounds the
rounds and tells the model where it stands, and the transcript records
each one. What is missing is the completion criterion — and a criterion
that stops on "looks done" either quits early or never quits, so it needs
designing rather than guessing.

Then `/subagent` and `/send [agent-id]`, and whether external AI tools
arrive as one `/call_ai <tool>` rather than a command per vendor.

`/goal` was asked for alongside `/new` and `/save` and is not built: it
has nothing underneath it, and a standing objective is not a command with
a handler. It needs designing before it gets a name.

## Not Doing Now

- No DI kernel or contribution-point framework
- Mail sending remains intentionally disabled; daily mail support is
  draft-only
- User plugin files under `~/.chat/plugins/` stay off unless
  `chat-plugin-load-user-directory` is set
- Unknown slash commands stay ordinary text
- Shell history for `!!` stays per buffer rather than persisted

## Immediate Next Step

No deterministic implementation gap from the execution audit remains.
Run credential-dependent provider or live-server checks only when their
environments are intentionally available.

Only `kimi-code` declares a `:context-window`; every other provider falls
back to `chat-context-window-default` at 131072. That default is wrong in
both directions — it over-promises for small models and wastes most of a
1M window — and now that the allocation table derives every allowance
from it, a wrong window silently mis-sizes the whole budget. Declaring
the real window per provider is a small change with a large effect on how
honest the panel is.
