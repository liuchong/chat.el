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
- Per-step pre-step hooks run before `transform-context-fn`, and
  provider options/tool exposure are rebuilt after that transform
- `prepare-next-turn-fn` may append structured context before a continued
  turn after response processing
- Steering and follow-up queues default to FIFO and can opt into LIFO per
  run; public clear APIs must keep both queues explicit
- Cancellation runs registered callbacks and is checked between tool
  calls so a cancelled batch cannot continue to later tools
- Streaming completion emits `stream-result` before the normal result
  path, carrying accumulated text plus native tool metadata
- Persist assistants that still store `tool-results` on the same struct
  are expanded at the convertToLlm boundary so older sessions keep working
- Native zero-argument tool schemas encode as an empty object with empty
  `required`, and forged tools persist their declared parameter schemas
- Provider tool exposure is filtered through the active session's
  `tool-config`, and direct execution must reject tools disabled by that
  same overlay
- Tool events carry owner, sensitivity, and effect metadata when a tool
  declares it, so approval and status surfaces share one permission
  contract
- Runtime argument validation must enforce the same required fields,
  primitive JSON types, enumerations, and additional-properties boundary
  advertised to providers. JSON false counts as a present boolean.
- Approval is required when either a legacy tool id, declared sensitivity,
  declared effect, or call-specific approval predicate marks the call as
  sensitive. Metadata is an enforcement contract, not display-only data.
- Optional user plugin loading evaluates only enabled NAME.el files and
  registration must happen before `chat-plugin-start-enabled`.
- Session state may add parent, branch, leaf, and summary entries while
  keeping `chat-session-format-version` stable; old files omit those
  fields and load with defaults
- JSONL append must preserve record boundaries after a partial trailing
  line, and load-time recovery must mark unfinished assistant/tool pairs
  instead of creating synthetic success messages
- Compaction cut points must not split an assistant `tool_calls` message
  from its matching `:tool` results
- Work orchestration tools must read and write through the executing
  session when one exists; background process tasks stay cancellable and
  keep bounded logs
- Workflow state is declarative data. It may store ordered steps and
  cancellation state, but must not evaluate arbitrary Lisp from records
- MCP clients are optional JSON-RPC transports. Stdio clients own a
  process lifecycle; HTTP requests are single JSON-RPC POST calls; both
  keep request/response state keyed by JSON-RPC id
- Sub-agents must isolate child sessions and return parent-safe
  summaries. External subprocess backends capture output to logs and
  expose cancellation without requiring external binaries in canonical
  tests
- Capability packs must be exposed through session tool overlays.
  Profiles should keep code, office, and daily surfaces from advertising
  the full global tool catalog
- Daily mail support is draft-only; sending is not registered as a tool

## Regression Guard

- `tests/unit/test-chat-agent.el` covers JSON tools, native tools,
  truncated refusal, parse-error follow-up, no-tool steer, follow-up,
  context transforms, next-turn prepare hooks, queue order, cancellation
  callbacks, cancelled batches, and plugin block hooks
- `tests/unit/test-chat-llm.el` covers tool role payloads, persisted
  result expansion, null content, and OpenAI `tool_calls` decode
- `tests/unit/test-chat-stream.el` covers streamed tool_call merging
- `tests/unit/test-chat-ui.el` and `tests/unit/test-chat-code.el` cover
  ordered transcript persistence and active-run input steering
- `tests/unit/test-chat-plugin.el` covers buffer privacy scope plus
  call-specific approval, plugin lifecycle states, dependency retry,
  user-plugin allowlisting, and owned resource rollback
- `tests/unit/test-chat-tool-caller.el` covers native schema and forged
  parameter persistence, runtime argument validation, plus session-overlay
  advertisement/execution filtering
- `tests/unit/test-chat-approval.el` covers metadata-driven and
  call-specific approval requirements
- `tests/unit/test-chat-session.el` covers session tool-config
  persistence, branch metadata, append-boundary recovery, interrupted
  tool-pair detection, and safe compaction cut indices
- `tests/unit/test-chat-work.el` covers background task execution/stop,
  session-local work records, declarative workflow cancellation, and
  work tool metadata
- `tests/unit/test-chat-mcp-subagent.el` covers MCP JSON-RPC response
  handling, stdio lifecycle, mocked HTTP, in-process child-session
  isolation, and external subprocess output capture
- `tests/unit/test-chat-capability-packs.el` covers profile overlays,
  office tools, daily diary/draft tools, and capability metadata
