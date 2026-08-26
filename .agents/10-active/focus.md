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
growth in the fixed region of the context. Six defects came out with it,
two of them silent data loss: frontmatter was matched with `.` and so
never parsed across lines, losing every title and date to a filename
fallback, and CJK titles were slugified by deleting non-ASCII, which made
them all collide on the empty string. Loading the file also wrote to disk
whenever a `wiki` directory sat beside `default-directory` — which, in the
test runner, is this repository. Decision 0015 records it.

Canonical suite: 931 tests passing.

## Next Stage

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
