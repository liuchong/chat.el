# Focus

- Type: progress
- Attention: active
- Status: active
- Scope: current-stage
- Tags: focus, current, stage

## Doing Now

The input command layer is in place. Chat input parses through
`lisp/core/chat-command.el` and dispatches through a name table in
`chat-ui.el`. Shell execution, history repeat, the session working
directory, ephemeral queries and a literal escape all work, and command
syntax accepts fullwidth punctuation without touching arguments.
Canonical suite: 627 tests passing.

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
