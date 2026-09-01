# Collaborative Session Groups

Status: accepted design; implementation deferred
Date: 2026-09-01
Scope: dynamic groups of independently owned collaborating sessions

## Goal

Allow several existing or newly created sessions to collaborate on one large
body of work while each session keeps an independent context, Goal, Plan, tasks,
permissions and lifecycle. A group is a high-cohesion communication and
coordination boundary, not a merged mega-session.

This Spec records the design only. It does not authorize implementation in the
current objective.

## Relationship To Existing Contracts

Spec 027 defines global discovery guards, pair channels, parent/child relations,
roles, topics and per-session recall. This Spec adds explicit group membership,
group channels, routing and shared coordination records. Spec 033 supplies remote
transport and headless placement when members are not local.

Session context, Goal, Plan Mode, work plan, task, note, wire and evidence stores
remain authoritative for their domains. Group state references them and never
copies their full content.

## Core Invariants

1. Membership never merges session context or instruction scope.
2. Every group message has an explicit sender, audience, purpose and provenance.
3. Joining grants only the capabilities declared by the membership role.
4. Leaving or closing a member does not delete its session or historical evidence.
5. A closed member receives no new delivery; reopening does not replay effects.
6. Shared decisions name the exact proposal revision and approving members.
7. Group coordination cannot bypass each member's approval, task, Goal or Plan
   state machine.
8. Delivery is idempotent and ordered per channel; no global total order is
   inferred from clocks.
9. Group summaries are bounded and queried on demand, never resident complete
   histories in every member prompt.
10. The pre-1.0 implementation uses one current schema and no compatibility path.

## Group Contract

`chat-session-group` schema version 1 contains:

- stable group ID, revision, display name and bounded purpose;
- owner principal and explicit project/workspace scope;
- state: `forming`, `active`, `paused`, `closing`, `closed` or `cancelled`;
- optional parent Goal reference and roadmap reference;
- membership policy and default role profile IDs;
- channel IDs and coordination record IDs;
- created, updated, paused and closed timestamps;
- bounded status, blocker and completion summaries.

`cancelled` is terminal. `closed` accepts only an explicit `reopen` transition
which increments both revision and activation epoch under the same stable group
ID. The prior epoch remains immutable history, and no old message or assignment
is redispatched. This clean current contract may be revised before implementation
if product testing proves a different lifecycle is clearer.

## Membership Contract

`chat-session-group-member` contains:

- stable membership ID and revision;
- group ID, session ID and authenticated owning principal;
- role profile and declared capabilities;
- state: `invited`, `active`, `paused`, `leaving`, `left`, `closed` or `rejected`;
- join source: existing session, new child session or explicit external session;
- allowed channels, content scopes and task/decision permissions;
- joined, updated and terminal timestamps;
- last acknowledged channel sequence and bounded unread counts.

Adding an existing session requires explicit consent from its owner and a guard
decision based on requested scopes. Creating a new member produces a normal
session with its own identity. Parent/child relation is recorded separately and
is not inferred from group membership.

Members may leave and later rejoin through a new membership revision while the
group is active. Closing a member pauses or closes its collaboration attachment;
the session itself remains independently usable unless separately stopped.

## Channels And Messages

Each channel declares group ID, purpose, audience policy, ordering sequence,
retention and content limits. Channel kinds are:

- `coordination` for plans, status and blockers;
- `evidence` for bounded evidence references and review findings;
- `discussion` for exploratory conversation;
- `decision` for versioned proposals, votes or approvals;
- `broadcast` for owner-authored group notices.

A `chat-group-message` stores message ID, channel sequence, sender membership,
audience, kind, timestamp, content reference, causal references, idempotency key
and delivery status. Complete content remains in the authorized channel store.
Wire events retain bounded metadata.

Messages are data until a receiving session explicitly admits them. A receiver
can acknowledge, reject, discuss, add a requirement intake, link evidence or
propose a Goal/Plan change. Delivery never injects another Agent's text as system
instructions or silently starts a tool.

## Coordination And Decisions

A group may have a coordinator, several coordinators or no coordinator. The role
controls routing and proposal administration, not authority over member sessions.

Shared work uses explicit records:

- work proposal: objective, scopes, dependencies, expected outputs and revision;
- assignment: proposal revision, target membership and acceptance state;
- progress: bounded status and evidence references;
- decision: exact proposal revision, required voters, decisions and outcome;
- completion: reconciled assignments, unresolved blockers and evidence digest.

No assignment is active until the target member admits it. Reassignment does not
erase prior attempts. A group completion claim cannot mark member Goals or plans
complete; it references their authoritative terminal evidence.

## Routing And Fairness

Routing may use role, capability, current load, project scope and explicit user
priority. It must not inspect unrelated private context. Equal-priority work uses
age and stable ID as tie-breakers. Backpressure is visible; a busy member can
decline or defer without losing the proposal.

Cycles in assignment dependencies block scheduling with an explicit diagnostic.
One task cannot be owned concurrently by two members. Redundant independent
investigations require distinct task identities and a later comparison record.

## Lifecycle Operations

- create a group from an existing session or an explicit member set;
- invite, accept, reject, pause, resume, leave, close and rejoin membership;
- add a new or existing session after group creation;
- create, close and inspect channels;
- send, acknowledge, reject and recall authorized messages before admission;
- propose, assign, reassign, discuss and decide shared work;
- inspect bounded membership, unread, blocker and evidence projections;
- pause, close or cancel the group without deleting member sessions;
- export a privacy-filtered group summary with explicit participant consent.

## Privacy And Authorization

Catalog visibility does not imply group eligibility. Joining, channel read,
message send, evidence read, assignment and decision are separate capabilities.
Membership changes are audited and take effect at an exact group revision.

Private session transcripts, prompts, reasoning, notes, file bodies, credentials
and tool output are not shared by default. References are dereferenced only after
recipient authorization. Removing a member stops future access but does not
rewrite already authorized immutable evidence; retention policy governs deletion.

## UI Projection

The native group view shows bounded member state, role, active assignment,
blockers, unread counts and recent coordination records. Opening a member session
is an explicit action. The input work shelf may show only the owning session's
active group assignment and unread count; it is not a second group store.

Local, headless and remote members use the same projection. Network transport
state is shown separately from member task or completion state.

## Implementation Sequence

1. Freeze group, membership, channel, message and proposal schemas.
2. Implement deterministic local groups over Spec 027 pair-channel primitives.
3. Add admission, assignment and versioned decision state machines.
4. Add bounded native views and shelf projection.
5. Add dynamic membership, leave/rejoin and close/reopen flows.
6. Integrate Spec 033 remote transport without changing group semantics.
7. Run privacy, concurrency, ordering, fairness and long-horizon evaluations.

## Acceptance

- adding, leaving, closing and rejoining members never merges or deletes sessions;
- one delivered group message creates at most one admitted requirement per member;
- unauthorized members receive neither channel metadata nor content bytes;
- a group message cannot execute a tool or change instruction authority directly;
- 100 concurrent messages preserve per-channel order and idempotent delivery;
- assignment cycles, duplicate ownership and stale proposal revisions fail closed;
- closing a group stops delivery and leaves every member session independently
  usable;
- remote disconnect is distinguishable from member pause, task failure and leave;
- group summary size remains bounded as transcript and evidence history grows;
- canonical and dedicated deterministic suites pass with zero unexpected result.

## Deferred Work

- implementing groups in the current objective;
- automatic organization-wide session scanning;
- implicit membership based on shared project path;
- unrestricted transcript federation;
- voting or consensus semantics beyond explicitly configured decision policies.
