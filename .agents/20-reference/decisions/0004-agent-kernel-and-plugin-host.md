# Decision 0004

- Type: decisions
- Attention: reference
- Status: accepted
- Scope: agent-kernel
- Tags: agent, plugin, tools, emacs

## Title

Extract the agent kernel and extend the host through Emacs plugins

## Context

The loop, UI, tools, and LLM adapters were mixed. The kernel needed to
match a small event-driven loop: one transcript language, convert only
at the provider boundary, refuse truncated tool calls, and keep
steering separate from follow-up. Emacs already has features, hooks,
and buffers; a second DI runtime would fight that.

## Decision

- Put the loop in `lisp/agent/` (`types`, `loop`, public `chat-agent`)
- Keep `lisp/core/chat-agent.el` as a load-path shim
- Advertise tools through the provider tool API; keep JSON-in-text as
  fallback
- Store tool results as `:tool` messages, not system prose
- Persist loop-emitted assistant/tool messages in order from host event
  handlers; UI and code-mode finalizers only render the completed state
- Add a small plugin host in `lisp/plugin/` with `define`, `inject`,
  `provide`, and start/stop
- Ship an `emacs` plugin for read-only live buffer, imenu, xref, and
  project.el tools
- Do not eval `~/.chat/plugins/` unless the user sets
  `chat-plugin-load-user-directory`

## Consequences

- UI and code mode stay hosts around the same loop
- Session reload keeps provider tool-call pairing intact for new runs
- New Emacs capabilities register as plugins and tools, not loop
  branches
- Sequential tool execution remains the default because approval UI is
  synchronous and Emacs is single-threaded
