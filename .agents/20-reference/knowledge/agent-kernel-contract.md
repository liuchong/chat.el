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
- Streaming normalization covers text, typed reasoning deltas, native
  tool starts/input fragments, nested stop reasons, and terminal provider
  errors. `max_tokens` maps to `length` before tool execution checks.
- Tool batches preserve provider order in their result vector. Only
  asynchronous, non-conflicting reads may overlap; write/destructive and
  approval-bearing calls carry exclusive scheduler accesses.
- Cancelling a run must invoke every active asynchronous tool handle and
  prevent late callbacks from appending transcript messages.
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
- Plugin ownership uses one newest-first resource stack across tools,
  services, and hooks. Rollback restores replaced values and always runs
  after teardown, including teardown failure.
- Persisted forged tools retain owner, sensitivity, effects, parameter
  enumerations, and provider-visible schema constraints.
- Session state may add parent, branch, leaf, and summary entries while
  keeping `chat-session-format-version` stable; old files omit those
  fields and load with defaults
- JSONL append must preserve record boundaries after a partial trailing
  line, and load-time recovery must mark unfinished assistant/tool pairs
  instead of creating synthetic success messages
- Compaction cut points must not split an assistant `tool_calls` message
  from its matching `:tool` results
- Message/state updates use same-directory temporary files and atomic
  rename; a crash cannot expose a half-written new record set.
- Regenerate and edit-resend create child sessions from a message
  boundary. The original session remains unchanged and records the branch.
- Durable compaction records the covered message id. Automatic pre-step
  pressure may iterate deterministic summaries; the manual command uses
  the session model asynchronously and persists the result.
- Interrupted tool recovery is explicit: mark missing calls failed,
  discard the unfinished assistant turn, or keep it pending. Recovery
  never fabricates successful tool output.
- Declarative workflows may contain only registered tool steps and
  explicit approval checkpoints. They cannot evaluate Lisp or recursively
  invoke workflow-control tools.
- Workflow state is persisted after each step. Conditions inspect only
  prior persisted status/result values; failures pause at the current
  index, while approval advances only after an explicit decision.
- Background task terminal states run `chat-work-task-finished-hook' and
  may emit a desktop notification; cancellation uses the same terminal
  notification contract.
- MCP configuration is inert at startup. Connection performs initialize,
  initialized notification, and tool discovery; discovered schemas become
  namespaced forged tools with remote annotations mapped to effects.
- Stdio and Streamable HTTP MCP calls use async callbacks and cancellation.
  HTTP accepts JSON or SSE bodies and preserves the server session id.
- Nested sub-agents run `chat-agent-start' with copied session capability
  overlays, bounded depth/steps, and an isolated child transcript. Only a
  final summary enters the parent tool result.
- External sub-agents receive one JSONL request on stdin. Their process,
  status, output log, and cancellation remain addressable by id.
- Capability profiles are enforced by the session overlay before provider
  schema generation, not only at execution time.
- Programming completion runs the target file's native CAPF at an explicit
  line/column. Office Org and Dired mutations stay inside approved roots.
- Web reading accepts only HTTP(S), uses Emacs rendering, truncates output,
  carries network/outbound approval metadata, and exposes an asynchronous
  cancellable runner.
- Daily correspondence creates local records or unsent message-mode
  buffers; no capability-pack tool sends mail.
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
  callbacks, cancelled batches, async read overlap, ordered results,
  write serialization, async handle cancellation, and plugin block hooks
- `tests/unit/test-chat-llm.el` covers tool role payloads, persisted
  result expansion, null content, and OpenAI `tool_calls` decode
- `tests/unit/test-chat-stream.el` covers streamed tool-call merging,
  reasoning, nested stop reasons, and terminal provider errors
- `tests/unit/test-chat-ui.el` and `tests/unit/test-chat-code.el` cover
  ordered transcript persistence and active-run input steering
- `tests/unit/test-chat-plugin.el` covers buffer privacy scope plus
  call-specific approval, plugin lifecycle states, dependency retry,
  user-plugin allowlisting, mixed-resource replacement restoration,
  teardown-failure cleanup, and owned resource rollback
- `tests/unit/test-chat-tool-caller.el` covers native schema and forged
  parameter persistence, runtime argument validation, plus session-overlay
  advertisement/execution filtering
- `tests/unit/test-chat-approval.el` covers metadata-driven and
  call-specific approval requirements
- `tests/unit/test-chat-session.el` covers session tool-config
  persistence, branch metadata, append-boundary recovery, interrupted
  tool-pair detection/recovery, sibling branch preservation, atomic
  append, and safe compaction cut indices
- `tests/unit/test-chat-context.el` covers automatic durable summaries,
  summary reuse, and asynchronous model compaction
- `tests/unit/test-chat-work.el` covers ordered conditional execution,
  durable approval resume, failure retry, cancellation, and task
  completion notification hooks
- `tests/unit/test-chat-mcp-subagent.el` covers stdio/HTTP/SSE protocol
  handling, async dispatch, schema-aware discovery, nested kernel
  isolation, registration, and shared lifecycle events
- `tests/unit/test-chat-capability-packs.el` covers CAPF, rendered web
  content, Org capture/update/schedule/agenda, Dired operations, Calc
  conversion, draft-only correspondence, and provider schema filtering
- `tests/integration/test-chat-work-platform-integration.el` verifies a
  discovered remote tool executing inside a durable resumable workflow
- `tests/e2e/test-chat-work-platform-e2e.el` verifies primary agent
  synthesis after remote MCP and isolated nested-agent tool paths
