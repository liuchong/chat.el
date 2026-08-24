# Focus

- Type: progress
- Attention: active
- Status: active
- Scope: current-stage
- Tags: focus, current, stage

## Doing Now

Stage 2 kernel parity is complete. The agent kernel now supports
per-step context transforms, next-turn prepare hooks, FIFO/LIFO queue
delivery, explicit queue clearing, cancel callbacks, cancelled
tool-batch termination, and normalized `stream-result` events. Ordered
assistant/tool persistence and project-scoped Emacs tools remain the
active transcript and privacy baseline. Suite: 532 tests passing.

## Not Doing Now

- No DI kernel or contribution-point framework
- No parallel file-tool execution (Emacs is single-threaded; approval stays serial)
- No session tree branching
- User plugin files under `~/.chat/plugins/` stay off unless
  `chat-plugin-load-user-directory` is set
- Anthropic streaming tool_use deltas are not accumulated yet; OpenAI
  compatible stream tool_calls are

## Immediate Next Step

Stage 3: evolve `lisp/plugin/chat-plugin.el` into an owner-scoped
runtime with lifecycle state, owned tool/hook rollback, session overlays,
and unified permission metadata.
