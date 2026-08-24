# Focus

- Type: progress
- Attention: active
- Status: active
- Scope: current-stage
- Tags: focus, current, stage

## Doing Now

Stage 4 durable session runtime is complete. Sessions now persist
parent/branch/leaf metadata, message parent/branch fields, and durable
summary records while keeping the current JSONL format version. Append
resumes after a partial trailing line, loads compute interrupted
tool-run recovery metadata, and `chat-session-tree.el` provides a
tabulated-list tree browser. Suite: focused Stage 4 tests passing;
canonical suite pending before commit.

## Not Doing Now

- No DI kernel or contribution-point framework
- No parallel file-tool execution (Emacs is single-threaded; approval stays serial)
- No destructive branch truncation UI beyond existing explicit truncate helpers
- User plugin files under `~/.chat/plugins/` stay off unless
  `chat-plugin-load-user-directory` is set
- Anthropic streaming tool_use deltas are not accumulated yet; OpenAI
  compatible stream tool_calls are

## Immediate Next Step

Stage 5: implement background tasks, plan/TODO/goals, and resumable
declarative workflows.
