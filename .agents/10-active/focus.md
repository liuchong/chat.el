# Focus

- Type: progress
- Attention: active
- Status: active
- Scope: current-stage
- Tags: focus, current, stage

## Doing Now

Stage 6 MCP and sub-agent backend work is complete. `chat-mcp.el`
provides optional JSON-RPC stdio/HTTP request primitives with
initialize/list/call/cancel/reconnect/teardown lifecycle, and
`chat-subagent.el` provides in-process child-session isolation plus an
external subprocess-agent backend with captured output. Suite: focused
Stage 6 tests passing; canonical suite pending before commit.

## Not Doing Now

- No DI kernel or contribution-point framework
- No parallel file-tool execution (Emacs is single-threaded; approval stays serial)
- No destructive branch truncation UI beyond existing explicit truncate helpers
- No automatic workflow step execution yet; workflows are durable
  declarative state with cancellation
- No bundled real MCP server is required in the canonical suite; fake and
  mocked transports remain authoritative
- User plugin files under `~/.chat/plugins/` stay off unless
  `chat-plugin-load-user-directory` is set
- Anthropic streaming tool_use deltas are not accumulated yet; OpenAI
  compatible stream tool_calls are

## Immediate Next Step

Stage 7: ship programming, office, and daily capability packs with
session profiles and scoped approvals.
