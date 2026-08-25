# Focus

- Type: progress
- Attention: active
- Status: active
- Scope: current-stage
- Tags: focus, current, stage

## Doing Now

Both budgets are in place: steps in `lisp/agent/chat-agent-budget.el`,
context in `lisp/core/chat-context-budget.el` with per-category
allowances and a declared-residency parser beside it. The typed
transcript model and the request projection are in place too.
Canonical suite: 727 tests passing.

The input command layer landed earlier: chat input parses through
`lisp/core/chat-command.el` and dispatches through a name table in
`chat-ui.el`, with shell execution, history repeat, the session working
directory, ephemeral queries and a literal escape.

## Next Stage

Render from `chat-transcript-plan`. The model is complete and the data is
stored, but both displays still draw an assistant turn into one mutable
region, so intermediate steps remain invisible on screen. That is the
whole reason the transcript work was started, and it is not finished
until a display reads it.

After that: fold interaction, the `auto` mechanism (declarative
`:repeatable` on commands plus session default-command continuation),
and specs for `/subagent`, `/send` and an external-AI prefix.

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
