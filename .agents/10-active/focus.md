# Focus

- Type: progress
- Attention: active
- Status: active
- Scope: current-stage
- Tags: focus, current, stage

## Doing Now

Stage 3 scoped plugin and permission runtime is complete. The plugin
host now tracks pending/active/failed/disposed states, retries pending
dependencies, records owned services/tools/hooks, and rolls them back
when stopped. Session tool overlays filter advertised and executed
tools, and tool events carry owner/sensitivity/effect metadata. Suite:
focused Stage 3 tests passing; canonical suite pending before commit.

## Not Doing Now

- No DI kernel or contribution-point framework
- No parallel file-tool execution (Emacs is single-threaded; approval stays serial)
- No session tree branching yet
- User plugin files under `~/.chat/plugins/` stay off unless
  `chat-plugin-load-user-directory` is set
- Anthropic streaming tool_use deltas are not accumulated yet; OpenAI
  compatible stream tool_calls are

## Immediate Next Step

Stage 4: add durable session tree/branch metadata, crash-safe append
semantics, compaction records, and interrupted-run recovery.
