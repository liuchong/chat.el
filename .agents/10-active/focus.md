# Focus

- Type: progress
- Attention: active
- Status: active
- Scope: current-stage
- Tags: focus, current, stage

## Doing Now

Stage 1 correctness is complete. The agent kernel persists ordered
assistant/tool messages through `chat-agent-transcript`, supports
mid-run steering before the default stop path, keeps forced stop first,
preserves provider `tool_call_id`, and exposes zero-argument native tool
schemas as empty objects. The Emacs plugin defaults live-buffer tools to
project/current-buffer scope and hard-denies credential-like buffers.
Suite: 527 tests passing.

## Not Doing Now

- No DI kernel or contribution-point framework
- No parallel file-tool execution (Emacs is single-threaded; approval stays serial)
- No session tree branching
- User plugin files under `~/.chat/plugins/` stay off unless
  `chat-plugin-load-user-directory` is set
- Anthropic streaming tool_use deltas are not accumulated yet; OpenAI
  compatible stream tool_calls are

## Immediate Next Step

Stage 2: complete kernel parity with per-step context transforms,
typed turn/tool events, cancellation propagation, stream contract
unification, and resource-aware scheduling.
