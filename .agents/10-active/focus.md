# Focus

- Type: progress
- Attention: active
- Status: active
- Scope: current-stage
- Tags: focus, current, stage

## Doing Now

Stage 7 capability packs are complete. `chat-capability-packs.el`
registers programming, office, and daily tools, with session profiles
for code, office, and daily surfaces. Programming covers diagnostics,
compile/test background tasks, and read-only status; office covers Org,
Dired-style file operations, and Calc; daily covers calendar/diary,
notifications, and unsent mail drafts. Suite: focused Stage 7 tests
passing; canonical suite pending before commit.

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

Stage 8: run final canonical verification, refresh docs if counts drift,
and create the final verified stage commit.
