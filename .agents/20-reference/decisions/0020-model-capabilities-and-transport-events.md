# Decision 0020

- Type: decisions
- Attention: reference
- Status: accepted
- Scope: agent-runtime
- Tags: models, capabilities, transport, streaming, discovery, reasoning

## Title

Resolve model facts before dispatch and normalize every transport into events

## Context

The runtime previously reached models through separate streaming, asynchronous
and compatibility paths. Each path preserved a different subset of reasoning,
tool-call and usage data, while provider behavior was partly implied by default
options or model names. That made a provider switch capable of changing core
behavior after dispatch, where the only remaining response was a remote error.

Model discovery creates a second ordering problem. Dynamic facts are useful,
but they must not erase explicit configuration, and a stale or newer cache must
not silently redefine what a request is allowed to do.

## Decision

`chat-model-capabilities` version 2 is the provider-neutral model contract. It
records streaming, tools, tool-choice modes, reasoning, reasoning continuation,
input modalities,
structured output, context and output limits, and supported request options.
`unknown` is distinct from both true and false. Core behavior never infers a
capability from a model-name pattern.

Capability declarations resolve in this order:

1. provider fallback;
2. static model declaration;
3. discovered model fact;
4. explicit user declaration.

Within one source, a model declaration overlays its provider declaration.
Discovery uses a versioned, expiring and atomically replaced cache. Unknown
newer cache schemas are rejected before live state changes; corrupt local cache
data is discarded in favor of static declarations.

`chat-model-request-events` is the high-level request boundary. It validates
known capability conflicts before transport creation, then projects streaming
and non-streaming adapters into `chat-model-event` version 1. Its stable event
vocabulary is `started`, `text-delta`, `reasoning-delta`, `tool-call-delta`,
`usage`, `completed` and `error`. Events carry request identity, provider,
model, sequence and bounded normalized payloads. One request emits exactly one
terminal event even if a low-level callback fires more than once.

Low-level request functions remain adapter APIs. The agent loop, UI helpers,
context compaction, Guard and coding helpers use the normalized runtime or its
result compatibility wrapper. Protocol-shaped payloads do not escape the model
adapter boundary.

Reasoning remains metadata on the assistant step that produced it. OpenAI
compatible adapters use the selected model's `reasoning-replay` mode. The mode
is `tool-calls` when only assistant tool-call messages need continuation,
`all-assistant` when every assistant message must carry the field, and `unknown`
when no provider-specific continuation field is authorized. Required replay is
a field-presence contract: an assistant step with no recorded reasoning carries
an empty string instead of silently omitting `reasoning_content`.
Reasoning support and continuation shape are separate facts: a model may expose
reasoning without accepting either OpenAI-compatible replay shape.

## Consequences

Provider additions must declare known facts and may add a discovery function;
they do not add model-name branches to the loop. Known invalid requests fail
locally with a useful reason. Unknown facts preserve compatibility but remain
inspectable, so uncertainty is visible instead of being converted into a false
claim.

Streaming and non-streaming paths now have the same observable vocabulary.
Compatibility wrappers keep current callers stable while new runtime features
can consume events directly. Raw usage may exist inside a transient transport
event, but session audit projections retain only bounded normalized counters.

## Verification

The M2 implementation is covered by 1405 passing tests. Offline fixtures cover
two protocol shapes, streaming and asynchronous results, reasoning, text,
partial tool calls, zero-valued usage counters, discovery precedence and cache
versioning, pre-dispatch rejection, duplicate callbacks, tool-call-only replay
and all-assistant replay.
