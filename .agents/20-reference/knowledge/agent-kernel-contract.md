# Knowledge Item

- Type: knowledge
- Attention: reference
- Status: active
- Scope: agent-kernel
- Tags: agent, tools, loop, convertToLlm

## Problem

The agent loop, LLM payload, and session history must stay on one
message contract. If the loop invents system prose for tool results, or
the LLM layer drops empty assistant messages that carry tool_calls, the
next turn cannot pair `tool_call_id` with results.

## Symptoms

- The model repeats the same tool after a successful call
- Tool-only provider replies (null content) error as unexpected format
- Truncated `finish_reason=length` still executes incomplete arguments
- Code mode injects a second system summary on top of `:tool` messages

## Resolution

- Keep `chat-message` as the loop language. Convert to provider JSON
  only in `chat-llm--format-messages`
- Prefer native `:tool-calls` on the transport result. Parse JSON-in-text
  only when that list is empty
- Append an assistant message with `tool-calls`, then one `:tool`
  message per result with `:tool-call-id` metadata
- Persist those emitted assistant/tool messages in order through
  `chat-agent-transcript`; UI finalizers render only and must not create
  a second bundled assistant history entry
- Refuse tool execution when `finish-reason` is `length`; feed the
  truncated constant back as a `:tool` result
- `chat-agent-steer` injects before the next LLM call, including when
  the current no-tool turn would otherwise hit the default stop path.
  Explicit stop predicates remain higher priority.
- `chat-agent-follow-up` runs only after the loop would stop
- Persist assistants that still store `tool-results` on the same struct
  are expanded at the convertToLlm boundary so older sessions keep working
- Native zero-argument tool schemas encode as an empty object with empty
  `required`, and forged tools persist their declared parameter schemas

## Regression Guard

- `tests/unit/test-chat-agent.el` covers JSON tools, native tools,
  truncated refusal, parse-error follow-up, no-tool steer, follow-up,
  and plugin block hooks
- `tests/unit/test-chat-llm.el` covers tool role payloads, persisted
  result expansion, null content, and OpenAI `tool_calls` decode
- `tests/unit/test-chat-stream.el` covers streamed tool_call merging
- `tests/unit/test-chat-ui.el` and `tests/unit/test-chat-code.el` cover
  ordered transcript persistence and active-run input steering
- `tests/unit/test-chat-plugin.el` covers buffer privacy scope
- `tests/unit/test-chat-tool-caller.el` covers native schema and forged
  parameter persistence
