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
`lisp/core/chat-command.el` and dispatches through a name table in
`chat-ui.el`, with shell execution, history repeat, the session working
directory, ephemeral queries and a literal escape.

The display now draws that record instead of keeping its own copy.
Committed history is redrawn from `chat-session-messages`; a live tail
holds only what has arrived and not been recorded; `message-appended`
hands one to the other, which is what keeps an intermediate step on
screen. Reasoning and tool work fold behind a summary row, interim prose
is italic, the answer is ordinary text and never folds. Decision 0010
records the shape and what it replaced.

Canonical suite: 781 tests passing.

## Next Stage

The `auto` mechanism. Two things share the name and both are wanted: a
session's default command continuing without being retyped, and an agent
running multiple rounds until its goal is met. `!!`, `/ask`, `/agent`,
`/plan` and external-AI calls are repeatable and should engage it;
`/goal`, `/cd`, `/pwd` and `/status` are not — a goal is a standing
objective, not a loop.

The intended shape is declarative: `:repeatable` on a command definition
rather than a list of names checked at the call site.

After that: specs for `/subagent` and `/send [agent-id]`, and an
external-AI prefix — `/call_ai <tool>` rather than one command per
vendor.

## Not Doing Now

- No DI kernel or contribution-point framework
- Mail sending remains intentionally disabled; daily mail support is
  draft-only
- User plugin files under `~/.chat/plugins/` stay off unless
  `chat-plugin-load-user-directory` is set
- `/new`, `/list`, `/save`, `/clear` and the `/wiki-*` help entries stay
  unimplemented, and unknown slash commands stay ordinary text
- Shell history for `!!` stays per buffer rather than persisted

## Immediate Next Step

No deterministic implementation gap from the execution audit remains.
Run credential-dependent provider or live-server checks only when their
environments are intentionally available.

`chat-wiki-command-handler` has no caller. Either wire the documented
`/wiki-*` names into `chat-ui--slash-commands` or drop them from
`chat-commands-help`, so the help text stops promising them.

Only `kimi-code` declares a `:context-window`; every other provider falls
back to `chat-context-window-default` at 131072. That default is wrong in
both directions — it over-promises for small models and wastes most of a
1M window — and now that the allocation table derives every allowance
from it, a wrong window silently mis-sizes the whole budget. Declaring
the real window per provider is a small change with a large effect on how
honest the panel is.
