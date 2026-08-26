# Stage: one text, two readings

Specs 005 and 006. Markdown shown as a document, and MDP read as data.

## What was wrong

Emacs had no Markdown engine here, only two unrelated thin coats of paint.
`chat-ui--insert-formatted-response` coloured closed fences on every insert;
`chat-ui--fontify-markdown-lite` added headings and bold once, at the end of
a turn. Everything else -- inline code, italics, links, lists, blockquotes,
tables, rules, task boxes -- sat in the buffer as literal source. No marker
was ever hidden, so what was on screen was the source and not the document.
Code blocks parsed out their language tag and then used it to pick between
two faces, so every language was one colour.

The two coats also disagreed. The finalize-time pass ran in exactly one
place, so the next redraw -- a fold, a reopen, an appended message -- dropped
the headings and bold it had added. The streaming path and the redraw path had
been producing different styling for the same text all along. And two
identical faces, `chat-code-block-face` and `chat-ui-code-block-face`, split
one visual surface between the two paths.

Some paths did not format at all: a quick answer and an error message were
bare `insert`.

## What was built

`lisp/core/chat-align.el` -- laying out columns by display width, on its own
because there are three callers and the wrong number of implementations is
two. `string-width`, never `length`.

`lisp/core/chat-markdown.el` -- one pure renderer. Same source, same result,
with no reference to a buffer, a window's width or the time. That is what
makes one renderer possible for four paths: they are not four callers who
must remember to agree, they are four callers with one input.

Markers are hidden with `invisible` and never deleted or displayed away, so
`kill-region` and a mouse selection give back the Markdown the model wrote.
`C-c C-;` shows them. Code blocks get their real major mode under
`delay-mode-hooks` and `condition-case`, from an explicit language table --
never `(intern (concat lang "-mode"))`, which would let a remote input decide
which package gets loaded -- with results cached, since a block is
re-rendered on every piece that arrives.

`lisp/core/chat-mdp.el` -- the codec, the machine view, and the annotation.
Written from the protocol specification, not linked against its Rust
implementation. All eight error codes are detectable and carry a line number.
`false`, `null`, `[]` and `{}` are four distinct values, because `nil` is
three of them at once in Elisp and an encoder cannot tell which to write.

Tool calls may now arrive in MDP as well as JSON, and which format arrived is
counted. `chat-tool-caller--fix-broken-json` did not follow: its reason for
existing is that JSON cannot survive how models write, and copying the same
pile of empirical repairs onto a new format would bring the old format's
illness with it. MDP's tolerance comes from its comment rule instead.

## What the work found

Three bugs, each caught by an invariant rather than by looking.

The checkbox path reassembled the line from its parts and the space between
the bullet and the box was not one of the parts, so `- [ ] todo` rendered as
`-[ ] todo`. A test asserting the box displays as a box passes on that; the
one asserting the source text survives does not.

MDP's rule against tab indentation never fired, because tabs had been kept
out of the pattern for a field -- so a tab-indented field matched nothing,
and a line that matches nothing is a comment by specification. The stricter
format was the more silent one. Recognise first, refuse second.

Generalising the streaming cut from fences to blocks turned the fast path
from "append the delta" into "redraw the unfinished tail". That is more work
and it is necessary work: appending only what is new means the block was
already drawn as prose by the time the rest of it arrived, so a table never
got its columns and a list item never got its hanging indent. The cost is
bounded by the tail, and capped again when the tail is itself long.

## Held back, on purpose

Spec 006 asks for the prompt to require MDP and for tool results to be
returned in it. Neither is done, and the reason is the spec's own: dropping
the JSON branch on a feeling would be betting usability on one. The same
logic reversed holds equally -- changing what the prompt asks for is also
betting usability on a feeling, and there was no way to check against real
models here.

What exists now is the state in which that evidence accumulates: both formats
are accepted and the hits are counted. One hazard is recorded in the spec for
whoever makes the flip, because it is a new way to be wrong rather than a
missing feature: an MDP payload can parse successfully and mean the wrong
thing, giving a call with empty arguments where malformed JSON would have
given no call at all.

## Verification

1217 tests, all passing. 68 new: 33 for the renderer and the alignment, 35
for the codec, the views and MDP tool calls.

Three stale tests were rewritten rather than deleted, since in each case the
behaviour changed deliberately: the fence-safe prefix now measures blocks,
the finalize-time styling pass no longer exists because styling arrives with
the text, and MDP's independence from the renderer is asserted about the
source, since by the time a whole suite has run everything is loaded.
