# 0009 — One chat surface

Status: accepted
Date: 2026-08-26

## Context

There were two chat interfaces. `chat.el` opened a `chat-mode` buffer;
`chat-code.el` opened a `chat-code-mode` buffer. They were introduced as
different things — general conversation and programming — and each grew
its own copy of everything a chat display needs: send a request, stream a
reply, show status, summarize a tool call, bind a key.

The copies drifted, and each drifted in a way the other needed.

The code side learned to cut a streaming update at a fence boundary, so a
half-written code block never renders as literal backticks. It learned to
summarize a tool result by kind, so a directory listing reads as file
names and a search reads as matches. It learned to ask for an output
token budget the provider would actually honour.

The chat side learned to check a buffer is still alive before drawing into
it. It learned to read the project's own instruction files. It learned
the context budget, the step budget, and resident context.

Every one of those fixes landed on one side only. The question that made
this undeniable was the plainest one available: what is the difference
between these two? The honest answer was that one had features the other
should have had, in both directions, and no principle divided them.

The features that were genuinely code-specific turned out to be few:
project context, coding prompts, LSP lookups, and the edit proposal
workflow. None of those needs a buffer of its own. They need a session to
remember a project root, a focus file and a context strategy.

## Decision

One surface. Code capability is a property of a session.

There is one major mode, `chat-mode`, one keymap, one renderer, one
request pipeline, one status line, one tool display. A coding session is
an ordinary chat buffer whose session metadata carries a project root, a
focus file and a context strategy. The header shows those when they are
set. The edit and context keys report plainly that a session lacks code
capability rather than being absent from the map.

`chat-code-from-chat` turns capability on for the session in front of
you, without restarting the conversation. Capability lives in metadata,
so it is saved with the session and restored when the session is
reopened, and a coding session appears in the ordinary session list.

### Staged, because the pieces failed differently

Session model first: capability into metadata, `chat-code-session`
removed. This is what makes the rest possible — as long as a code session
was a different struct, code had to be routed somewhere.

Pipeline second: for each duplicated pair, keep the better behaviour,
move it to `chat-ui.el`, delete the other. 1712 lines left
`chat-code.el`; 475 arrived in `chat-ui.el`, the difference being the
duplication itself.

Keymap third. The two maps collided on one key: `C-c C-a` accepted an
edit on one side and toggled auto-approval on the other. Merging two maps
resolves a collision silently — the later `define-key` wins and nothing
reports the loss. Auto-approval moved to `C-c C-t`.

Rendering last, on the one renderer, which was the point of merging
first.

### What guards it

Deleting 1700 lines by hand invites deleting a line that was still
needed, and it happened: a reachability pass keyed on the `chat-code`
prefix reported three helpers as dead. They were called from
`chat-edit-*` commands in the same file, which the prefix did not match.
`tools/dead-code-report.el` now also walks from everything in the file
that is not a `chat-code` definition, so a called function cannot be
reported as dead.

Two invariants are asserted rather than reviewed:

The keymap and `chat-commands-help` agree, key by key, in both
directions. A key the help names is bound; a key that is bound is
documented. The `C-c C-a` collision existed as documentation before it
existed as code — both surfaces described that key for their own command
— so this test would have caught it before the maps were merged.

The docs name commands that exist. The cheatsheet listed eight
`chat-code-quote-*` and `chat-code-ask-*` commands that had become
`chat-quote-*` and `chat-ask-*` long before; the README listed the same
eight plus a help command that no longer existed. Nine dead names in
user-facing docs, and no way to notice. `test-docs.el` reads every `M-x`
in the docs and requires it to be a command.

## Consequences

Everything both surfaces did, every session now does. A general session
gets fence-safe streaming and readable tool summaries; a coding session
gets project instructions, the context budget and the step budget.

A fix lands once. This is the whole point, and it is why the merge came
before the transcript rendering that prompted it — that work would
otherwise have been written twice, and the second copy would have drifted
from the first.

Old customizations keep working. `chat-code-use-streaming`,
`chat-code-max-output-tokens`, `chat-code-request-timeout` and the rest
are obsolete aliases to their `chat-ui-` equivalents. The three whose
meaning did not survive — `chat-code-max-tokens`,
`chat-code-history-max-tokens`, `chat-code-request-safety-margin` — are
marked obsolete with what replaced them.

`chat-code-mode` is gone. Anything bound in it, or any hook added to it,
moves to `chat-mode`. This is a breaking change for a configuration that
customized the code buffer specifically.

The docs still live at `code-mode-*.md` paths. The contents no longer
describe a mode, and the paths are stale; renaming them would break
external links, so they stay until there is a reason to move them.
