# Focus

- Type: progress
- Attention: active
- Status: active
- Scope: current-stage
- Tags: focus, current, stage

## Doing Now

Stage 8 final verification is complete. All planned work-platform
stages are implemented and committed through Stage 7, and the final
canonical suite passed with 556 tests. The current remaining work is
normal product hardening beyond this plan, not an unfinished plan item.

## Not Doing Now

- No DI kernel or contribution-point framework
- No parallel file-tool execution (Emacs is single-threaded; approval stays serial)
- No destructive branch truncation UI beyond existing explicit truncate helpers
- No automatic workflow step execution yet; workflows are durable
  declarative state with cancellation
- No bundled real MCP server is required in the canonical suite; fake and
  mocked transports remain authoritative
- Mail sending remains intentionally disabled; daily mail support is
  draft-only
- User plugin files under `~/.chat/plugins/` stay off unless
  `chat-plugin-load-user-directory` is set
- Anthropic streaming tool_use deltas are not accumulated yet; OpenAI
  compatible stream tool_calls are

## Immediate Next Step

No immediate next stage from the attached plan remains.
