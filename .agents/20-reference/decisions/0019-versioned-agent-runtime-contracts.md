# Decision 0019

- Type: decisions
- Attention: reference
- Status: accepted
- Scope: agent-runtime
- Tags: runtime, contracts, events, tasks, models, content, profiles, persistence

## Title

Build the agent runtime around five versioned contracts

## Context

The project has a capable agent loop, tools, approval, context management,
background work and child agents. Their integration points grew independently:
agent callbacks, plugin hooks, approval review records, task structs and UI
state each described a different part of the same run. This made extensions
depend on implementation details and made a finished session hard to audit as
one ordered account.

A provider-neutral runtime also cannot be built by spreading model names and
protocol exceptions through the loop. Nor can future task recovery, multimodal
content and reusable agent roles safely depend on transient UI structures.

## Decision

The runtime has five public contracts. Each owns a schema version from its
first persisted form. Additive optional fields may retain a version; changing
meaning, required fields or wire shape requires a version increment and an
explicit reader migration.

### `chat-event`

`chat-event` is the ordered lifecycle fact. Version 1 carries identity, type,
time, session/turn/task/parent correlation, source, bounded payload, extension
context and policy outcome. A live `subject` may be inspected or replaced by a
synchronous blocker but is never persisted.

Only declared events are blockable. Blockers run in registration order before
the action. Observers run after persistence and cannot alter or fail the run.
Security boundaries default fail-closed; notification boundaries default
fail-open. Timeout, invalid return, handler identity and reason are audit data.
Runtime-owned wire fields cannot be supplied or replaced by producers.

The stable lifecycle vocabulary begins with session, turn, prompt, tool,
permission, task, child-agent and compaction edges. Diagnostic events may use
the bus without joining that stable list.

### `chat-task`

`chat-task` will be the durable unit of work in M4. Version 1 must separate
identity and parentage, requested work, execution state, resumability,
cancellation, result summary and artifact references. Processes, buffers,
callbacks and other live handles are adapters attached at runtime, never task
state. Existing background task records migrate through a reader rather than
being rewritten in place.

### `chat-model-capabilities`

`chat-model-capabilities` will describe in M2 what a selected model and
protocol can actually accept: tools, tool-choice modes, thinking, structured output,
streaming, content modalities, context limits and option support. The core
loop asks capabilities; provider adapters translate them. Unknown capability
is explicit and must not be guessed from a model name.

### `chat-content-part`

`chat-content-part` will be the M5 typed request and transcript content unit:
text, image, audio, file reference, tool call, tool result and reasoning
metadata. Version 1 keeps transport serialization outside the type. Plain text
messages remain readable through an adapter so migration can be incremental.

### `chat-agent-profile`

`chat-agent-profile` will compose in M3 instructions, model preference,
capability requirements, tool overlay, approval mode, context policy and resource budget.
It names a role without creating a second runtime. Profiles may inherit only
through an explicit resolved representation; persisted runs record the
resolved profile identity and revision needed for reproduction.

## Dependency Direction

The loop depends on contracts, not UI or provider implementations. Provider,
tool, task and UI adapters may depend on the contracts. Persistence projects
contracts into bounded data and never serializes live objects. The UI observes
runtime state and issues commands; it does not own lifecycle truth.

`chat-event` is first because every later migration needs an auditable path.
Capabilities follow because every extension and content adapter must reason
from explicit model facts. Profiles and extension contracts then compose that
behavior. Durable tasks follow the lifecycle and extension contracts; typed
content follows the normalized model transport. Recovery, memory and Termini
integration build only on those public boundaries.

## Persistence Rules

- Every new persistent document or record carries `schema_version` or
  `schemaVersion`.
- Readers accept known older versions and normalize them to the current
  in-memory contract.
- Unknown newer major versions fail with a bounded diagnostic and leave source
  data untouched.
- Writers emit only the current version and use atomic replacement for mutable
  documents or append-only records for event streams.
- Secrets, full live objects and unbounded model/tool output do not enter audit
  envelopes.

## Consequences

M1 introduces a small synchronous cost at the three blockable boundaries and
an append for session-scoped events. In return, Guard reviews, permission
decisions, tools, compaction, tasks and child agents share one chronology.

Extensions gain stable integration points but must declare whether they are a
blocker or observer and must tolerate schema evolution. Provider additions
will require capability declarations rather than aliases hidden in core code.

The five contracts are not five simultaneous rewrites. Each later contract is
introduced behind an adapter and migrated in a separately reversible stage.

## Verification

The M0/M1 implementation is covered by 1387 passing tests. The relevant tests
exercise registration order, blocker modification and refusal, timeout,
fail-open/fail-closed behavior, metadata ownership, non-persistence of live
subjects, successful and failed turns, resource conflict recomputation,
permission request/resolution pairs, refused compaction, background tasks and
child-agent lifecycle records.
