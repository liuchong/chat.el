# Agent Runtime Roadmap

Status: active
Date: 2026-08-28
Decision: 0019

## Final Goal

Turn `chat.el` into an Emacs-native, provider-neutral and auditable Agent
Runtime. A run should be able to plan, use tools, request permission, compact
context, delegate work, survive interruption and explain afterwards what
happened and why. Emacs remains the primary interaction surface; the runtime
must not depend on a particular UI, provider or tool transport.

The final system is successful when:

- one versioned lifecycle stream can reconstruct every meaningful transition;
- work is represented by durable tasks that can resume or terminate cleanly;
- provider differences are contained in capability and transport adapters;
- text and non-text content share one typed representation;
- reusable agent profiles compose behavior without forking the runtime;
- safety decisions are explicit, blockable where necessary and always audited;
- common editing and coding flows remain responsive and native to Emacs;
- offline tests cover core behavior, with opt-in live verification for adapters.

## Design Principles

1. Contracts before features. Shared types and lifecycle semantics land before
   new UI or provider-specific behavior.
2. One source of truth. The runtime owns state; UI, persistence and telemetry
   are projections.
3. Provider neutrality. Core code asks about capabilities and typed content,
   never model-name folklore.
4. Durable intent, live adapters. Persist task intent and outcomes, not process
   handles, buffers or callbacks.
5. Bounded audit. Keep identifiers, decisions, summaries and measurements;
   keep secrets and unbounded payloads out.
6. Reversible migration. Each phase has compatibility adapters and can be
   reviewed or reverted without requiring the next phase.
7. Safety is a lifecycle boundary. Security hooks fail closed; display and
   telemetry hooks fail open.

## Runtime Layers

The dependency direction is:

```text
UI commands and views
        |
Agent profiles and orchestration
        |
Agent loop, task runtime, approval, context
        |
Versioned contracts: event, task, capabilities, content
        |
Provider, tool, process and persistence adapters
```

No lower layer reads UI state to decide runtime behavior. Provider adapters do
not mutate transcripts. Persistence does not receive live runtime objects.

## Phase Plan

### M0: Contract Baseline

Goal: freeze names, ownership and migration rules before broad refactoring.

Deliverables:

- Decision 0019 for the five contracts;
- schema version rules for all newly touched persistent formats;
- a dependency map showing contract and adapter boundaries;
- baseline test and performance measurements.

Acceptance:

- every planned contract has an owner and versioning rule;
- no phase requires an unversioned persistent shape;
- the canonical suite passes before and after the documentation-only part.

Status: complete.

### M1: Unified Lifecycle Events

Goal: make runtime transitions observable and selectively blockable through one
contract.

Deliverables:

- `chat-event` version 1 with identity, correlation and provenance;
- ordered blocker and observer registration;
- per-event timeout and fail-open/fail-closed policy;
- session wire persistence with runtime-owned metadata;
- lifecycle emission for sessions, turns, prompts, tools, permissions, tasks,
  child agents and compaction;
- Guard review migration through the same event path.

Acceptance:

- a blocker can allow, modify or refuse the action before it occurs;
- malformed or timed-out security blockers cannot authorize execution;
- observer failures cannot fail a run;
- successful, failed and cancelled paths close their lifecycle once;
- a session log contains enough correlation to order nested work;
- legacy Guard review readers continue to see their established record kind.

Status: complete.

### M2: Model Capabilities And Transport

Goal: give the runtime one provider-neutral model contract and one normalized
stream, instead of branching on model names or transport implementations.

Deliverables:

- `chat-model-capabilities` version 1 for tools, tool-choice modes, thinking,
  structured output, streaming, modalities, context limits and options;
- static declarations, optional provider discovery, a provenance-aware cache
  and deterministic fallback when discovery is unavailable;
- one normalized stream for current streaming, asynchronous and compatibility
  request paths;
- stream events for text, reasoning, tool-call deltas, usage, completion and
  bounded errors;
- pre-dispatch request validation and provider adapter fixtures.

Acceptance:

- the core loop contains no model-name branch for supported behavior;
- unknown capability differs from false and remains visible in diagnostics;
- unsupported combinations fail before dispatch with a useful reason;
- discovery cannot silently override explicit user configuration;
- offline fixtures prove equivalent normalized events across transport paths.

Status: complete.

### M3: Hooks, Skills And Custom Agents

Goal: make runtime behavior extensible without cloning the loop or injecting
provider-specific prompt branches.

Deliverables:

- versioned hook declarations built on the M1 blocker/observer contract;
- discoverable, lazily loaded skills with explicit instructions, tools and
  capability requirements;
- `chat-agent-profile` version 1 for resolved instructions, model preference,
  tool overlay, approval, context policy and budgets;
- custom-agent composition and session-level selection;
- validation, provenance and conflict diagnostics for every resolved overlay.

Acceptance:

- hooks, skills and custom agents all use the same runtime loop;
- incompatible capability requirements fail before a run starts;
- loading a skill cannot silently widen tool or approval permissions;
- resolved instructions and overlays are inspectable and reproducible;
- changing a profile never rewrites earlier session history.

### M4: Unified Tasks And Subagents

Goal: represent foreground work, background commands, workflows and delegated
work with one durable, parallel and cancellable task contract.

Deliverables:

- `chat-task` version 1 with the state path `queued -> running ->
  waiting-approval/needs-attention -> completed/failed/canceled/interrupted`;
- stable parent/child identity, cancellation tokens and terminal idempotence;
- bounded parallel scheduling with resource-conflict checks;
- adapters for current background work, workflows and in-process or external
  subagents;
- task tree/detail views projected from runtime state.

Acceptance:

- no task reaches two terminal states;
- parent cancellation follows an explicit child policy;
- parallel tasks preserve lifecycle ordering and resource safety;
- existing task files migrate through readers without rewriting source data;
- a subagent is a child task, not a separate orchestration system.

### M5: Multimodal Content

Goal: carry text, images, audio, files and tool data through one typed content
pipeline without collapsing content into strings.

Deliverables:

- `chat-content-part` version 1;
- adapters for current text messages, reasoning and tool records;
- provider serializers and stream assemblers for supported modalities;
- native transcript rendering, validation, size limits and artifact references;
- explicit capability-driven rejection or transformation of unsupported parts.

Acceptance:

- text-only sessions keep their current user-visible behavior;
- unsupported content is never silently dropped;
- streamed parts retain order and tool-call identity;
- large binary data is referenced rather than embedded in session events;
- old text-only sessions remain readable through the compatibility adapter.

### M6: Checkpoints, Worktrees And Backends

Goal: let substantial work pause, resume and move between execution backends
without confusing durable intent with live processes or editor objects.

Deliverables:

- checkpoints for approval, user input, external completion and interruption;
- resume rules with attempt history and idempotency classification;
- backend abstraction for local processes, isolated worktrees and future
  remote execution;
- artifact handoff and explicit reconstructed/restarted state;
- abandoned-work handling and cleanup of runtime-owned resources.

Acceptance:

- restarting Emacs reconstructs resumable intent without resurrecting a stale
  process;
- a non-idempotent action is never retried without renewed permission;
- worktree ownership and cleanup are explicit and auditable;
- moving backends preserves task, parent and event correlation;
- recovery leaves no orphan process, timer, buffer or callback.

### M7: Memory, Tracing And Evaluations

Goal: improve long-running agent quality with inspectable memory and measurable
behavior rather than hidden prompt accumulation.

Deliverables:

- scoped short- and long-term memory with provenance, retention and deletion;
- trace reconstruction from lifecycle, task, model and artifact records;
- performance counters for first event/token, tools, compaction and total turn;
- deterministic scenario fixtures and Guard, tool, recovery and quality evals;
- bounded export and comparison tools for regression analysis.

Acceptance:

- every retrieved memory item states its source and scope;
- memory can be disabled or deleted without corrupting sessions;
- traces reconstruct nested and parallel work from stable identifiers;
- offline evals are deterministic and separate from opt-in live checks;
- regressions are reported with reproducible inputs and contract-level events.

### M8: Termini Integration

Goal: add `termini.el` as the Emacs-native bridge between the Agent Runtime and
the Termini platform while keeping both sides independently usable.

Deliverables:

- a versioned Termini Bridge for task dispatch, progress, cancellation,
  artifacts and completion;
- `termini.el` commands and concise native status/detail views;
- reconnect, duplicate-delivery and partial-failure handling;
- capability negotiation between local runtime and Termini backends;
- compatibility, stress, security and opt-in live integration suites.

Acceptance:

- local `chat.el` use does not require Termini;
- bridge retries are idempotent and preserve correlation identifiers;
- disconnect and reconnect cannot duplicate a completed action;
- remote state is a projection or backend result, never hidden UI truth;
- the complete M0-M8 suite remains deterministic offline, with live checks
  isolated and explicitly enabled.

## Execution Order

Each phase follows the same sequence:

1. Write or update the contract and acceptance tests.
2. Add the new implementation behind the existing API.
3. Migrate one producer and one consumer end to end.
4. Run focused tests, then the canonical suite.
5. Measure persistence size, latency and leak behavior where relevant.
6. Migrate remaining callers in small ownership groups.
7. Remove the compatibility adapter only after no production caller uses it.
8. Record the stage, unresolved risks and the exact verification result.

M2 starts only after M1 event ordering is stable. M3 consumes M2 capability
facts. M4 consumes M1 events and M3 extension contracts. M5 consumes M2
capabilities and normalized transport. M6 operates on M4 tasks and M5 artifact
references. M7 measures all preceding contracts. M8 integrates only through
the public event, task, capability and artifact boundaries.

## Quality Gates

Every phase must preserve:

- zero unexpected results in the canonical batch suite;
- `check-parens` and byte-compilation cleanliness for touched Lisp files;
- bounded persistent records and explicit schema versions;
- no secrets or live objects in audit data;
- no orphan processes, timers or temporary buffers from tests;
- conventional commit messages scoped to the completed phase;
- a stage record containing behavior, tests, measurements and follow-up risks.

## Current Baseline

M0, M1 and M2 are complete. The canonical suite passes 1405/1405. Model
capabilities now resolve from explicit facts and every application request path
projects into one versioned transport event vocabulary. The next implementation
stage is M3: compose hooks, lazy skills and custom agent profiles without
forking the runtime or widening permissions implicitly.
