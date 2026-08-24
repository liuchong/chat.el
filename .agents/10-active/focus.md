# Focus

- Type: progress
- Attention: active
- Status: active
- Scope: current-stage
- Tags: focus, current, stage

## Doing Now

Stage 5 work orchestration is complete. `chat-work.el` provides
cancellable background process tasks with persisted state/logs,
session-local plan/TODO/goal records, and declarative workflow records
that can be cancelled without evaluating untrusted Lisp. Work tools are
registered with owner/effect metadata and use the executing session for
durable state. Suite: focused Stage 5 tests passing; canonical suite
pending before commit.

## Not Doing Now

- No DI kernel or contribution-point framework
- No parallel file-tool execution (Emacs is single-threaded; approval stays serial)
- No destructive branch truncation UI beyond existing explicit truncate helpers
- No automatic workflow step execution yet; workflows are durable
  declarative state with cancellation
- User plugin files under `~/.chat/plugins/` stay off unless
  `chat-plugin-load-user-directory` is set
- Anthropic streaming tool_use deltas are not accumulated yet; OpenAI
  compatible stream tool_calls are

## Immediate Next Step

Stage 6: implement optional MCP stdio/HTTP clients plus in-process and
external subprocess sub-agent backends.
