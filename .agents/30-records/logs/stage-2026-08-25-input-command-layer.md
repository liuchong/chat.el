# Stage Record 2026-08-25: Input Command Layer

- Type: logs
- Attention: records
- Status: complete
- Scope: input-commands
- Tags: commands, shell, working-directory, punctuation, session-metadata

## Goal

Give chat input the command set the terminal front end already had:
shell execution, history repeat, and a working directory the session
keeps. Accept fullwidth punctuation so a Chinese input method reaches the
same commands.

## What Shipped

Three stages, each committed after its own tests passed.

1. `lisp/core/chat-command.el` parses a line of input into a command
   plist. Pure string handling, no buffer or session dependency.
2. `chat-session.el` gained a canonical metadata API and a session
   working directory. `chat-tool-caller--execution-directory` now prefers
   it over the code mode project root.
3. `chat-ui.el` dispatches through a name table instead of a nested
   `cond`, and `chat-tool-shell.el` gained an unrestricted path for
   commands a person typed.

Commands: `!<cmd>`, `!!`, `/cmd`, `!cd`, `/cd`, `/pwd`, `?<q>`,
`/question`, `/ask`, `/model`, `/cancel`, and `\<text>` for literal text.

## What The Investigation Found

Two facts changed the design and are worth keeping.

**Session metadata lookups were already broken across a reload.** The UI
helpers wrote a keyword plist and read it back with `plist-get`, but JSON
decoding returns an alist keyed by plain symbols. Verified directly: a
stored `:cwd` reads as `nil` after `chat-session-load` while
`(assoc 'cwd ...)` returns the value. The recent-target hints had been
losing data this way. Fixed at the root by making the alist shape
canonical rather than working around it at the call site.

**The tool caller binds its session with `let`, not `let*`.** The values
of the binding list are computed in the outer environment, so
`chat-tool-caller-current-session` is not visible while
`--execution-directory` runs. Reading the session from that variable
would have silently resolved the wrong session. The function takes the
session as an argument instead.

## Verification

- Full suite 627 passing, up from 598.
- 29 new tests: 12 parser, 5 session metadata and working directory, 2
  tool caller directory precedence, 10 UI dispatch and directory handling.
- End-to-end run in a real chat buffer confirmed: a fullwidth bang with a
  shell pipe returns the piped result; a fullwidth slash `cd` with an
  ideographic space changes the directory; `!pwd` and the resolved tool
  execution directory both report it; `!!` repeats; a reopened session
  restores it; `!echo "你好，世界（测试）"` reaches the shell with its
  punctuation intact; `\!text` sends literally.
- Changed files byte-compile without warnings.

## Deliberate Non-Goals

- Unknown slash commands stay ordinary text rather than raising an error,
  so slash-prefixed prose keeps working and the help entries that were
  never implemented do not start failing loudly.
- `/new`, `/list`, `/save`, `/clear` and the `/wiki-*` entries in
  `chat-commands-help` remain unimplemented. `chat-wiki-command-handler`
  exists but has no caller, so those names still fall through to the
  model.
- Shell history for `!!` is per buffer and is not persisted with the
  session.
- A directory change does not widen `chat-files-allowed-directories`.
