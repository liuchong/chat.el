# Session Collaboration, Recall And Requirement Admission

Status: accepted design; implementation deferred
Date: 2026-08-29
Scope: application-wide session collaboration and per-session durable recall

## Goal

Give every Agent enough durable, scoped evidence to continue long work without
forcing all history into every model request. New user requirements must be
captured immediately, but they must not repeatedly displace work already in
progress unless the user explicitly requests preemption or the runtime detects
a genuinely urgent condition.

The same foundation later supports guarded session discovery, local Agent
communication, parent/child collaboration, parallel topics, compaction recall
and a network adapter for the Termini JM message system.

This Spec records the complete design. It does not authorize implementation in
the current coding-reliability objective.

## Existing Contracts Remain Authoritative

This design composes existing stores instead of replacing them:

- session context stores canonical conversation messages used for continuation;
- the session wire in Spec 009 stores bounded typed events used for replay;
- structured work context in Spec 021 stores scoped instructions and work notes;
- durable work plans in Spec 022 own ordered TODO execution and evidence;
- Goal owns the durable objective and stopping condition;
- Plan Mode owns read-only planning permission and approval state;
- the input work shelf in Spec 026 is only a bounded UI projection.

The new user-input ledger is a durable read model over accepted input events. It
does not become a second editable transcript. Collaboration messages, intake
records, plans, Goals and topics keep separate schemas and identities; no field
called `status` is allowed to collapse these distinct state machines.

## Core Invariants

1. Every submitted user input receives a stable identity before dispatch.
2. Every new requirement is acknowledged and classified; none is remembered
   only through model attention.
3. Normal follow-up work is recorded and the current atomic plan item continues.
4. Explicit preemption, safety threats, imminent data loss and design-invalidating
   corrections may interrupt current work through a recorded transition.
5. User content, event evidence and collaboration data are isolated by session
   unless a declared relation and policy decision permits access.
6. Recall is on demand and bounded. Merely having history never injects it into
   every prompt.
7. Cross-session discovery exposes metadata first, content only after a separate
   scoped authorization.
8. No model output can silently acquire instruction authority through a note,
   event, message or imported history record.
9. All durable schemas reject unsupported future versions before mutation.
10. Pre-1.0 implementation is a clean current-schema implementation with no
    aliases, dual reads, migration branches or compatibility fallback.

## Requirement Admission And Preemption

### Admission Record

Every user input that adds, changes or cancels work may create a
`chat-requirement-intake` schema-version-1 record containing:

- stable intake ID and optimistic revision;
- source user-input ID, session ID, topic ID and turn ID when one exists;
- received timestamp, classified timestamp and monotonic session sequence;
- normalized title plus the exact source-content reference;
- kind: `new-requirement`, `correction`, `clarification`, `priority-change`,
  `cancel`, `status-question` or `conversation`;
- urgency: `immediate`, `high`, `normal` or `low`;
- disposition: `preempt`, `block-current`, `queue-after-current`,
  `merge-current`, `answer-inline` or `no-work`;
- status: `captured`, `scheduled`, `active`, `completed`, `superseded`,
  `cancelled` or `rejected`;
- affected Goal, plan, task, work-note and file-scope IDs;
- dependency and conflict IDs;
- bounded rationale, acceptance description and evidence IDs;
- classifier source: explicit user instruction, deterministic runtime rule or
  Agent proposal confirmed by the runtime;
- timestamps and bounded metadata.

The record stores references to complete input content instead of copying it.
An Agent may propose urgency and disposition, but deterministic policy validates
the transition and records the final reason.

### Preemption Classes

The admission policy evaluates in this order:

1. `explicit-preempt`: the user clearly says to stop, pause or replace current
   work and start the new request now;
2. `critical-runtime`: continuing risks security, privacy, irreversible data
   loss, destructive writes, credential exposure or a broken running system;
3. `blocking-correction`: the new input proves the current design, target,
   repository or acceptance condition is wrong, so continuing would create
   invalid work;
4. `urgent-deadline`: the user supplies a real deadline that cannot be met after
   the current atomic item;
5. `normal-follow-up`: useful work which does not invalidate the current item;
6. `conversation-only`: a status question, clarification already answerable or
   input that creates no work.

Classes 1-4 may preempt. Class 5 defaults to `queue-after-current`. Class 6 is
answered without changing the plan. Mere recency, repeated wording, length,
capitalization or emotional intensity never implies urgency.

### Atomic Continuation Boundary

The default continuation unit is the current durable plan item. For work without
a plan it is the smallest already-started operation that can reach a consistent
checkpoint without expanding scope.

A normal follow-up is captured, briefly acknowledged and queued while that unit
continues. When the unit reaches `completed`, `blocked` or an explicit safe
checkpoint, pending intake records are re-triaged by:

1. explicit user priority;
2. safety and data-loss risk;
3. whether they unblock accepted work;
4. dependency order;
5. Goal relevance;
6. age, then stable intake ID.

This is not pure FIFO, but equal-priority work cannot starve: age is a mandatory
tie-breaker. The runtime exposes the resulting order and rationale.

### Interaction With Goal, Plan And TODO

- Admission decides whether and when work enters execution.
- Goal decides the durable objective and stopping condition.
- A work plan decides ordered steps inside the active task.
- A requirement may append or replace only the pending future plan tail; it
  cannot rewrite completed evidence or the active item without an explicit
  preemption transition.
- A conflicting requirement is linked to the affected design and blocks
  destructive continuation until the design is revised into one coherent
  replacement.
- Capturing a requirement never means it is completed or accepted as correct.

The Agent receives a bounded projection containing the active item, the count of
pending requirements, any immediate blocker and at most the next three scheduled
titles. Full intake history is queried on demand.

### Goal Revision Awareness And Closeout

Requirement admission and Goal mutation are separate operations. A captured
follow-up receives its own intake identity; it does not implicitly replace the
active Goal or increment its revision. Only an authoritative change to the Goal
objective, constraints, success criteria, priority or stopping condition creates
a new Goal revision.

After such a revision, the next Agent step must re-read the authoritative Goal
projection before performing another governed action. The runtime records a
`goal-revision-observed` event linking the old and new revisions, affected task
and plan identities, and the resulting decision to continue, revise the pending
plan tail or block. Work prepared against an older revision cannot execute merely
because it was already queued.

Stage commits, evaluations, checkpoints and plan completion add evidence and
progress to the Goal; none of them independently completes it. Goal closeout must
reconcile every admitted requirement linked to the Goal as completed,
superseded, cancelled, rejected with reason or explicitly retained for later
work. Unreconciled intake prevents a successful terminal closeout but does not
erase completed evidence or force unrelated work to restart.

## Per-Session User Input Ledger

### Purpose

Each session keeps a clean durable stream containing only user-submitted input.
It exists so an Agent can later answer questions such as "what requirements did
the user add after the last compaction?" without scanning mixed assistant output,
tool results or unrelated sessions.

The ledger is not resident prompt context. A permanent capability fragment tells
the Agent that bounded query operations exist and when recall is appropriate.

### Storage And Authority

The canonical layout is:

```text
~/.chat/sessions/user-input/<session-id>/
  manifest.json
  entries-000001.jsonl
  index.json
```

Segments are append-only. `manifest.json` stores schema and segment identities;
`index.json` is an atomic rebuildable projection. No session writes user content
to a shared global ledger. A global catalog may store only session metadata and
counts.

The ledger is derived from accepted input events and can be rebuilt from the
session context, command records and wire evidence. It is immutable evidence,
not an independently editable source of conversation truth.

### Entry Schema

`chat-user-input-entry` schema version 1 contains:

- stable input ID, session sequence and content SHA-256;
- session, topic, turn, task, Goal, plan and intake IDs when applicable;
- wall-clock timestamp, monotonic receive time and timezone offset;
- exact typed text plus typed content-part references;
- UTF-8 byte size, character count, line count and measured token estimate;
- source surface and action: send, quick, command, stage, approval response,
  edit-resend, steering, automation or collaboration;
- parsed command identity and argument boundaries when the input is a command;
- locale, input language when known and model-request language when applicable;
- attachment IDs, MIME types, byte sizes and content digests, never embedded
  binary bodies or transient source paths;
- dispatch outcome: recorded, staged, queued, inserted, interrupted, executed,
  refused, failed, cancelled or superseded;
- related prior input IDs for edit, resend, correction and replacement;
- policy, checkpoint, request and error event IDs;
- bounded metadata and schema version.

Exact user text is never normalized in storage. Parsed command syntax is a
separate projection. Staged input receives an entry when submitted and later
links to the canonical sent turn; it is not rewritten in place.

### Query Contract

The Agent-facing query accepts session scope plus bounded filters:

- input ID or sequence range;
- timestamp range;
- topic, turn, task, Goal, plan or intake ID;
- action, outcome, command identity or attachment kind;
- exact text, tokenized terms or content digest;
- before/after cursor and result limit.

Default result count is 20 and the hard maximum is 100. Results return metadata
and bounded excerpts first. Complete text requires explicit entry IDs. Queries
return stable cursors and report omitted counts; they never concatenate the full
ledger into one prompt.

## Per-Session Runtime Evidence

Spec 009 remains the event-store contract and is extended with the following
requirements:

- every session has isolated event segments and indexes; no free-form global
  file contains conversation-level evidence;
- intake classification and every preemption decision emit typed events;
- input acceptance, command dispatch, model request, transport, tool, policy,
  approval, checkpoint, storage, filesystem, network, compaction, collaboration
  and UI recovery events share correlation IDs;
- failures record stable error code, operation, phase, outcome, retryability,
  related IDs, bounded human message and available OS/provider status;
- refused or failed writes explicitly record that no target was changed;
- disk-full, permission, serialization, network loss, timeout, cancellation and
  process failure are distinguishable;
- sensitive values and full message/tool bodies are referenced, not copied;
- the Agent knows a bounded session-event query exists and may use it to explain
  unexpected state before guessing.

Event files use immutable size-bounded segments and a rebuildable index. Rotation
never mixes sessions and never silently deletes unarchived evidence. Retention or
archival is an explicit user policy with visible diagnostics.

## Pre-Compaction Snapshots And Recall

Before transcript compaction commits, the runtime writes a structured immutable
snapshot manifest containing:

- snapshot ID, session and topic IDs;
- source message range and content digests;
- context bundle, Goal, plan, active requirement and work-note revisions;
- tool-call pairing and message-boundary indexes;
- counts, byte size, token estimates and creation time;
- the summary record that replaced the range;
- links to user-input and wire sequence ranges.

Snapshots live under the owning session and are indexed by time, topic and source
range. Recall operations return summaries and section indexes first, then bounded
message ranges by ID. Multiple compactions create multiple immutable snapshots;
no later compaction rewrites an earlier one.

## Global Session Catalog

Every session has stable ID, display name, status, project identity, topic count,
parent/child relation, role summary and last-activity time. The Agent knows it can
request a catalog when the task genuinely needs global awareness.

Catalog listing returns metadata only. It defaults to five sessions, uses a
configurable limit and exposes an explicit `more` cursor. It never loads every
session transcript to build a list.

### Catalog Guard

An unrelated session catalog request must include:

- requesting session and Agent identity;
- current user-input ID, not an unscoped copied prompt;
- current Goal, task and topic IDs;
- bounded reason;
- intended action: discover, inspect, message, coordinate or recover;
- requested fields, relation scope and result limit.

The guard may allow, deny or narrow the fields, relations and count. It records a
session-scoped review event with reasons. Denial is fail-closed and does not reveal
whether hidden sessions exist. A catalog authorization never authorizes transcript
content or message sending; those are separate decisions.

## Local Collaboration Channels

Two sessions communicate through an append-only pair-scoped channel with stable
message IDs, sender/recipient session and Agent IDs, timestamps, topic/task links,
reply/acknowledgement state, typed content references and policy evidence.

Messages are not injected into the recipient's active prompt. The recipient gets
a bounded unread projection and explicitly reads or acknowledges messages. A
message can propose work but cannot mutate the recipient's Goal, plan or notes.

Unrelated sessions require guarded discovery and send authorization. Parent,
child and sibling sessions use declared relationship policy with narrower scopes,
but relation alone never grants arbitrary project files or complete transcript
access.

## Parent, Child, Sibling And Role Contracts

Creating a child session declares:

- parent session, source topic and delegated task;
- role profile, model binding and capability profile;
- inherited context-fragment IDs and exact revisions;
- file/project scope, read/write resources and stopping condition;
- result channel and merge policy.

Children receive explicit snapshots, not a hidden concatenation of parent
context. They return structured results, evidence IDs, session location and
unresolved questions. Siblings communicate only through their common relation or
an authorized channel. A descendant cannot widen inherited scope.

Roles have stable IDs, purpose, responsibilities, non-responsibilities, preferred
model/capabilities, instruction fragments and allowed delegation shapes. Role
instructions remain attributable and scoped.

## Topics Inside One Session

A session has one main topic and may create parallel child topics. Each topic has
stable ID, parent topic, objective, status, context references, work notes, plan
and event sequence ranges. Topics share session identity but do not share a flat
mutable context buffer.

Cross-topic recall and merge use explicit references. A merge records selected
facts, decisions, evidence and unresolved work; it does not copy complete topic
history or elevate Agent text to user instruction. Main and child topics may run
independently within scheduler and resource limits.

## Termini JM Network Adapter

Local channels define the semantic contract. A later Termini JM adapter maps the
same identity, relation, message, acknowledgement and policy records onto network
transport. Registration, discovery, friendship and live receive are transport
operations; they cannot change local session authority or bypass catalog/content
guards. Offline delivery is durable and idempotent by message ID.

## Agent Capability Projection

A small resident fragment tells the Agent that it can:

- inspect pending requirement intake and scheduling reasons;
- query the current session's user-only input ledger;
- query current-session runtime failures and correlations;
- inspect compaction snapshots by index before loading content;
- request guarded global session metadata;
- communicate through declared local relationships and channels.

The fragment contains operations and limits, not ledger contents, session names
or global activity. The Agent should recall when evidence is missing or state is
surprising; it must not scan history routinely "just in case".

## Public Operations

The eventual API surface is grouped by authority:

- intake: capture, classify, list, reprioritize, schedule, preempt, supersede;
- user input: list metadata, search, get exact entries, inspect relations;
- events: query by correlation, kind, outcome, error and time;
- snapshots: list, inspect manifest, read bounded range;
- catalog: guarded list and `more`;
- channels: open, send, list unread, read, acknowledge;
- relations: create child, list relatives, inspect delegation, return result;
- topics: create, list, switch, query, merge and close;
- roles: list, inspect and bind;
- network: connect or disconnect the JM adapter without changing local records.

Every mutation takes the observed revision or idempotency key and emits a bounded
event. Every list operation is paginated and stable under concurrent append.

## Privacy And Security

- Session content never appears in an unrelated session's catalog row.
- Search defaults to the current session; global search is not implied by catalog
  access.
- Pair channels and child relations have explicit participants and scopes.
- Full user text, tool output, secrets and file bodies are absent from guard and
  event payloads unless the specific content operation is authorized.
- Export applies the privacy projection in Spec 024 and does not silently include
  private ledgers, event evidence, channels or snapshots.
- Deleting a session presents all owned stores as one deletion set; partial silent
  deletion is forbidden.

## Implementation Sequence

### Phase A: Admission And User Ledger

1. Define strict intake and user-input schemas plus validators.
2. Assign input IDs at the single UI/runtime submission boundary.
3. Persist per-session user-input segments and rebuildable indexes atomically.
4. Implement deterministic preemption policy and wire events.
5. Connect normal follow-ups to the pending work-plan tail without changing the
   active item.
6. Add bounded Agent projections and query operations.

### Phase B: Failure Evidence And Snapshots

1. Extend Spec 009 event vocabulary and correlation coverage.
2. Add storage, filesystem, transport and policy failure projections.
3. Write pre-compaction manifests before committing compaction.
4. Implement indexed bounded recall for events and snapshots.

### Phase C: Catalog And Local Channels

1. Extend the rebuildable session index with catalog metadata.
2. Add default-five pagination and `more` cursors.
3. Implement catalog guard request, narrowing and audit records.
4. Add pair-scoped local channels and unread projections.

### Phase D: Relations, Roles And Topics

1. Add explicit parent/child delegation records and result return.
2. Add role profiles and scope-preserving inheritance.
3. Add topic state, context references and structured merge.
4. Integrate these providers into the input work shelf without new truth stores.

### Phase E: JM Adapter And Evaluation

1. Map local channel semantics onto the Termini JM transport.
2. Prove offline idempotency, reconnection and policy preservation.
3. Run privacy, concurrency, compaction, restart and long-horizon evaluations.

## Acceptance

- 100 consecutive normal follow-up inputs are durably captured without changing
  the active item; all later become visible in deterministic schedule order.
- explicit stop/preempt, imminent destructive risk and blocking correction each
  interrupt at a safe boundary with one auditable reason.
- every submitted input, including commands, staged drafts and refusals, appears
  once in the owning session ledger with exact text, complete relation metadata
  and a valid digest.
- restart, index deletion and rebuild produce byte-equivalent ledger projections.
- an Agent can find one requirement among 10,000 user inputs through bounded
  metadata search without loading mixed assistant/tool history.
- permission, disk, network, timeout, cancellation and failed-write cases are
  distinguishable from session events and correlate to the originating input.
- two compactions and a restart preserve immutable snapshot indexes and allow
  exact bounded recall of both source ranges.
- catalog listing returns five rows by default, paginates stably and reveals no
  unrelated content; denied requests reveal no hidden-session metadata.
- local parent/child result return and sibling messages preserve declared scope,
  ordering, acknowledgement and idempotency.
- parallel topics do not leak notes, plans or unmerged content into one another.
- no resident context grows with ledger, event, catalog, channel or snapshot size.
- canonical tests and dedicated long-horizon, privacy and fault-injection suites
  pass with zero unexpected results.

## Non-Goals For The Current Objective

- implementing any phase of this Spec;
- network deployment or remote identity management;
- making global session history resident model context;
- using the global catalog as an automatic task scanner;
- replacing Goal, plans, work notes, session context or wire with one universal
  record;
- preserving experimental pre-1.0 storage shapes.

## Follow-On Design Boundaries

This Spec remains the authority for local discovery, admission, recall, pair
channels, relations, roles and topics. Later designs compose it without changing
those contracts:

- Spec 031 defines durable event-source observation and governed trigger
  admission;
- Spec 032 defines remotely stored scoped rule bundles;
- Spec 033 defines language-neutral headless and distributed session placement;
- Spec 034 defines dynamic collaborative groups over independently owned
  sessions.
