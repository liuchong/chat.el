# Focus

- Type: progress
- Attention: active
- Status: active
- Scope: current-stage
- Tags: focus, current, stage

## Doing Now

The agent kernel is extracted to `lisp/agent/` and covers the PI loop
contract: native `tool_calls`, JSON-in-text fallback, `:tool` transcript
messages, truncated refusal, steer/follow-up queues, and plugin hooks.
The emacs plugin exposes live buffers, imenu, xref, and project.el as
read-only tools. Suite: 519 tests passing.

## Not Doing Now

- No DI kernel or contribution-point framework
- No parallel file-tool execution (Emacs is single-threaded; approval stays serial)
- No session tree branching
- User plugin files under `~/.chat/plugins/` stay off unless
  `chat-plugin-load-user-directory` is set
- Anthropic streaming tool_use deltas are not accumulated yet; OpenAI
  compatible stream tool_calls are

## Immediate Next Step

Real world usage of native tool calling on Kimi/OpenAI/Claude, then
optional extra emacs plugins (completion-at-point, flymake) when a
concrete user path appears.
