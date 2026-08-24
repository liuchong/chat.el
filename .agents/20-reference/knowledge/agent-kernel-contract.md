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
- Refuse tool execution when `finish-reason` is `length`; feed the
  truncated constant back as a `:tool` result
- `chat-agent-steer` injects before the next LLM call.
  `chat-agent-follow-up` runs only after the loop would stop
- Persist assistants that still store `tool-results` on the same struct
  are expanded at the convertToLlm boundary so older sessions keep working

## Regression Guard

- `tests/unit/test-chat-agent.el` covers JSON tools, native tools,
  truncated refusal, parse-error follow-up, steer/follow-up, and plugin
  block hooks
- `tests/unit/test-chat-llm.el` covers tool role payloads, persisted
  result expansion, null content, and OpenAI `tool_calls` decode
- `tests/unit/test-chat-stream.el` covers streamed tool_call merging
