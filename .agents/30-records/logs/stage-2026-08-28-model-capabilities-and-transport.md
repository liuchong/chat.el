# Stage: Model Capabilities And Transport

- Type: logs
- Attention: records
- Status: complete
- Scope: agent-runtime
- Tags: models, capabilities, transport, streaming, discovery, reasoning

Date: 2026-08-28
Spec: 014
Decision: 0020

## Result

M2 gives the runtime one model capability contract and one normalized request
stream. Provider and exact-model declarations now resolve through explicit
source priority, preserving `unknown` as a first-class value. Optional dynamic
discovery sits behind a versioned expiring cache and deterministic static
fallback.

Streaming SSE and asynchronous responses both emit ordered
`chat-model-event` records for start, text, reasoning, tool-call deltas, usage
and one terminal outcome. The agent loop, UI helper requests, context
compaction, Guard and coding helpers have moved behind that boundary. Existing
result and chunk APIs remain as compatibility projections over the same event
stream.

## Correctness Details

- Known unsupported tools, tool-choice modes, structured output, reasoning,
  modalities, streaming and output limits fail before dispatch.
- Optional sampling controls known to be ignored are removed before request
  construction.
- Explicit user declarations outrank discovery; discovery outranks static and
  fallback facts.
- Unknown newer cache schemas do not mutate live state.
- Text, reasoning, partial tool calls, stop reasons and normalized usage survive
  both transport families.
- A request closes exactly once despite callback re-entry or duplicate errors.
- Models explicitly known not to support tools receive neither tool schemas nor
  tool instructions.
- Reasoning needed by a tool continuation is replayed only for a capable model
  and only on the assistant tool-call message that produced it.
- Agent session audit records retain bounded usage and tool-delta projections,
  never the raw provider usage object.

## Verification

The canonical suite passes 1405/1405 with zero unexpected results. Added tests
cover capability uncertainty and priority, provider refresh behavior, cache
round trips and future schemas, discovery hooks, preflight failures, ignored
options, normalized streaming fixtures for two protocol shapes, asynchronous
normalization, terminal idempotence, zero-token usage, raw SSE payload delivery
and reasoning continuation replay.

No background service was started. Test processes ran in the foreground under
the repository memory cap and timeout wrapper.

## Next Stage

M3 defines versioned extension declarations, lazy skills and resolved agent
profiles on top of M1 events and M2 capability facts. A profile must be
inspectable before a run and cannot widen tool or approval authority through a
skill overlay.
