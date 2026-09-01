# Event Source Subscriptions

Status: accepted design; implementation deferred
Date: 2026-09-01
Scope: durable event observation and governed task admission

## Goal

Allow a session or headless Agent to observe an explicitly configured event
source over time and turn qualifying observations into governed work. A
subscription may poll, receive a stream, or react to a schedule, but it must not
keep a model request open while waiting and must not bypass normal requirement,
task, approval, Goal, Plan or session boundaries.

This Spec records the design only. It does not authorize implementation in the
current coding-reliability stage.

## Existing Authorities

Subscriptions compose existing contracts instead of replacing them:

- Spec 009 owns session wire events and bounded audit evidence;
- Spec 016 owns scheduled runtime task identity, resources and cancellation;
- Spec 018 owns execution isolation and checkpoints;
- Spec 021 owns scoped instructions and work context;
- Spec 022 owns ordered TODO execution;
- Spec 027 owns requirement admission and the per-session input ledger;
- Goal owns the durable objective and stopping condition;
- Plan Mode owns read-only planning permission.

A subscription owns only observation intent, source cursor and trigger policy.
It is not a task queue, cron database, conversation transcript, Goal or Agent
memory store.

## Core Invariants

1. Waiting for an event consumes no model turn and holds no foreground Agent.
2. Every observation, delivery attempt and admitted trigger has a stable ID.
3. At-least-once source delivery never becomes duplicate task execution.
4. Source data is untrusted content, never instruction authority.
5. A trigger cannot widen the owning session's filesystem, network, tool or
   collaboration scope.
6. Polling and streaming are bounded by time, bytes, rate and retained history.
7. Restart resumes from an explicit durable cursor or reports that exact resume
   is unavailable; it never guesses silently.
8. No event automatically performs a destructive action merely because a model
   classified it as important.
9. Unsupported future schemas fail before mutation.
10. The pre-1.0 product has one current schema and no compatibility readers.

## Subscription Contract

`chat-subscription` schema version 1 contains:

- stable subscription ID, revision, owner session ID and optional Goal ID;
- source adapter kind and immutable source descriptor digest;
- display name and bounded purpose;
- lifecycle state: `inactive`, `active`, `paused`, `blocked` or `cancelled`;
- observation mode: `poll`, `stream` or `schedule`;
- trigger policy ID and immutable policy revision;
- capability requirements and declared read/write resources;
- bounded poll interval, timeout, byte limit and rate limit;
- durable opaque cursor plus cursor generation when the adapter supports resume;
- last observation, success, failure and trigger timestamps;
- consecutive failure count and bounded blocker summary;
- created and updated timestamps.

Only an explicit operation changes lifecycle state. Transient runner, process,
timer, callback, socket and credential objects are never serialized. `cancelled`
is terminal. A blocked subscription can resume only after its unblock condition
is satisfied and the expected revision still matches.

## Source Adapter Contract

An adapter exposes a single capability-shaped interface:

- `describe`: validate configuration without contacting the source;
- `preflight`: resolve credentials and runtime capabilities without starting;
- `observe`: return one bounded observation page and next opaque cursor;
- `acknowledge`: optional source acknowledgement after durable local commit;
- `close`: release transient resources idempotently;
- `redact`: project safe diagnostics from source-specific failures.

Adapters may represent HTTP responses, mounted-drive metadata, repository
changes, WebSocket or event-stream messages, date and calendar boundaries,
weather observations, or a user-installed Agent-executable adapter. Built-in and
installed adapters obey the same contract. Installed code receives no authority
from being an adapter and remains subject to plugin trust and capability rules.

The core never interprets an adapter's private cursor. Adapter configuration is
strictly typed and stored separately from credentials. A source which cannot
resume exactly declares `resume=latest|snapshot`; the UI and audit must show the
resulting gap risk before activation.

## Observation And Trigger Records

Each source result becomes a `chat-subscription-observation` record containing:

- observation ID, subscription ID, subscription revision and source generation;
- source event ID when supplied, otherwise a deterministic content identity;
- observed-at and source timestamp when supplied;
- cursor-before, cursor-after and bounded payload reference;
- payload byte count, content type and redaction summary;
- classification result: `ignored`, `candidate`, `triggered` or `rejected`;
- trigger-policy revision, reason code and correlated intake/task IDs.

The complete payload is stored only in an owning-session bounded content store.
Wire events retain identifiers, counts, digests and bounded summaries. Secret
fields are redacted before diagnostics, display, export or model projection.

Trigger policy is deterministic where possible: field comparison, threshold,
calendar boundary, digest change, debounce window and explicit filters. A model
may classify a bounded candidate only when the policy explicitly permits it.
Its output is a proposal which the deterministic policy validates.

## Delivery And Idempotency

The runtime commits an observation before advancing its durable cursor. A
qualifying observation creates exactly one requirement-intake record with an
idempotency key derived from subscription ID, policy revision and source event
identity. Admission then decides whether it becomes queued work, a notification,
a Goal update proposal or no work.

Creating an intake record does not create a model request. A runtime task is
created only after admission and normal policy checks. Retry reuses the same
observation and intake identities. Source acknowledgement happens only after the
local commit and is independently retryable; acknowledgement failure cannot
erase accepted local evidence.

## Scheduling And Resource Control

Subscription runners are children of a scheduler-owned service task, not of a
foreground model turn. They use bounded leases with generation fencing so a
restart or duplicate process cannot observe through two active owners.

- poll intervals use bounded jitter and cannot overlap for one subscription;
- streams reconnect with capped backoff and an explicit resume cursor;
- schedules use a timezone and next-fire instant, never free-form model timing;
- resource conflicts use Spec 016 declarations;
- cancellation closes the adapter once and emits one terminal fact;
- repeated failures move the subscription to `blocked` instead of retrying
  forever.

## Security And Privacy

Activation requires explicit user authorization of source kind, endpoint or
resource identity, credential reference, network/file capabilities and trigger
effect. Credentials remain in the configured credential provider and are never
written into subscription JSON, wire records, prompts or exports.

Remote content is data. It cannot alter system instructions, grant tools, change
approval mode, mutate Goal or Plan, create collaborators or expand source scope.
Any later action follows the same approval and execution rules as a direct user
request. Cross-session delivery requires a separate declared relation and policy
decision.

## Public Operations

- create and validate an inactive subscription;
- inspect effective source, policy, scope and capability requirements;
- activate, pause, resume, cancel and delete with expected revision;
- run one bounded dry observation without admitting work;
- list recent observation metadata and retrieve one authorized payload;
- inspect cursor, failures, trigger decisions and correlated intake/tasks;
- test trigger policy against an explicit saved fixture;
- rotate credentials by reference without rewriting historical records.

## Implementation Sequence

1. Freeze schemas, validators, state transitions and redaction rules.
2. Implement an in-memory deterministic fixture adapter and observation store.
3. Integrate leases, task scheduling, wire events and restart recovery.
4. Integrate requirement admission and idempotent trigger creation.
5. Add one polling, one streaming and one schedule adapter behind capabilities.
6. Add native inspection and explicit activation UI.
7. Add fault injection, privacy, rate, restart and long-horizon evaluations.

## Acceptance

- 10,000 duplicate source deliveries create one intake and at most one task;
- restart at every commit/ack boundary loses no accepted observation and creates
  no duplicate effect;
- an idle active subscription performs zero model calls;
- missing credentials, unsupported resume, rate limit, malformed payload,
  timeout, disk failure and cancellation remain distinguishable;
- two processes cannot own the same subscription generation concurrently;
- payload, diagnostics, wire and export byte limits hold under adversarial input;
- untrusted source text cannot modify authority or execute a tool by itself;
- paused and blocked subscriptions perform no observations;
- source acknowledgement failure preserves local committed evidence;
- canonical and dedicated deterministic suites pass with zero unexpected result.

## Deferred Work

- implementing any source adapter or runtime in the current objective;
- distributed ownership across machines, defined by Spec 033;
- collaborative routing to session groups, defined by Spec 034;
- a marketplace or public adapter registry;
- implicit activation inferred from conversation text.
