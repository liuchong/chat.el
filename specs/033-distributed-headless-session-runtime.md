# Distributed And Headless Session Runtime

Status: accepted design; implementation deferred
Date: 2026-09-01
Scope: protocol-based session execution across local and remote runtimes

## Goal

Let one durable session run without an attached Emacs UI, attach to a UI later,
or execute on another authorized machine without changing its conversation,
Goal, Plan, task or evidence identities. Headless and interactive operation are
two attachments to the same runtime contract, not two formats that require
conversion.

This Spec records the architecture only. It does not authorize a distributed
runtime implementation in the current objective.

## Existing Authorities

- session context remains the canonical conversation store;
- Spec 009 remains the bounded session wire and replay evidence;
- Spec 016 owns task lifecycle, scheduling and cancellation;
- Spec 018 owns checkpoint, workspace and execution capability boundaries;
- Spec 020 defines the existing optional Termini App Server bridge;
- Spec 024 controls public export;
- Spec 027 controls admission, recall, relations and local collaboration;
- Goal, Plan Mode and work plans retain their independent state machines.

The distributed runtime adds placement, lease and protocol facts. It does not
copy these authorities into a universal remote-session record.

## Core Invariants

1. Exactly one fenced runtime generation owns mutations for a session at a time.
2. UI attachment never grants execution authority or changes durable state by
   itself.
3. Disconnect is not cancellation, completion or failure.
4. Every mutating protocol operation has a caller-generated idempotency key.
5. Reconnect refreshes authoritative state and never replays mutation blindly.
6. Remote capability is explicit, versioned, identity-bound and non-widening.
7. Message, event and task ordering is monotonic per authority stream; wall-clock
   time is display metadata, not the ordering authority.
8. A machine never reads session content merely because it can discover session
   metadata.
9. Durable records contain no process handles, callbacks, sockets or credentials.
10. The runtime protocol is language-neutral and the pre-1.0 product keeps one
    current version without compatibility shims.

## Runtime Identity

`chat-runtime-instance` schema version 1 contains:

- stable runtime instance ID and authenticated principal ID;
- host identity, installation identity and process generation;
- supported protocol versions and versioned capability facts;
- runtime kind: `embedded`, `headless-local` or `remote`;
- state: `starting`, `ready`, `draining`, `disconnected`, `failed` or `stopped`;
- bounded resource limits and placement labels;
- last heartbeat, connected and stopped timestamps;
- bounded redacted failure summary.

A `chat-session-lease` binds session ID, runtime instance ID, lease generation,
fencing token, acquired/renewed/expiry timestamps and capability snapshot digest.
Only the current fencing token may append authoritative session state. A stale
owner can finish local cleanup but all later mutations are rejected.

Lease acquisition is an explicit control-plane operation. It cannot be inferred
from opening a buffer, receiving a message or seeing an expired heartbeat.
Failover records the old and new generations and requires recovery from the last
committed checkpoint.

## Control Plane And Data Plane

The control plane owns runtime discovery, authentication, capability negotiation,
session placement, lease fencing and attachment routing. It exposes bounded
metadata and never carries full transcript bodies in list operations.

The data plane carries versioned commands, events, content references and bounded
result pages for one authorized session. Large content uses a bounded attachment
or blob channel with digest and size verification. Backpressure is explicit; a
slow UI or observer cannot block session persistence or Agent execution.

The two planes may use a local stdio transport, the Termini message network, or
another authenticated transport adapter. Transport does not alter domain
semantics. Protocol conformance is tested independently of transport.

## Headless And UI Attachments

A headless runtime can admit work, execute tasks, wait for approval or input,
record events and reach terminal states with no display attached. It must expose
the same bounded status, cancellation and evidence operations as an interactive
runtime.

`chat-runtime-attachment` is an ephemeral authenticated view lease containing
attachment ID, principal, session, runtime generation, requested view capabilities
and last acknowledged event sequence. Attachments may be read-only or interactive.
An interactive attachment still uses normal admission and approval operations;
it cannot write directly to session files.

Detaching leaves the runtime and its tasks unchanged. Reattaching requests a
snapshot followed by events after a sequence cursor. If retained events no longer
cover the cursor, the server returns an explicit gap and a fresh bounded snapshot.
The client does not splice guessed history.

## Protocol Operations

Required operations are grouped by authority:

- runtime: negotiate, inspect capabilities, heartbeat and drain;
- placement: acquire, renew, release and inspect session lease;
- session: open metadata, snapshot, append admitted input and inspect status;
- event: subscribe from sequence, acknowledge and fetch bounded pages;
- task: list, inspect, cancel, resume and fetch bounded output;
- approval: list pending and submit a decision against exact revision;
- content: describe, read bounded bytes and verify digest;
- attachment: attach UI, renew view lease and detach.

Every request carries protocol version, request ID, principal, session when
applicable, runtime generation and deadline. Mutations also carry idempotency key,
expected durable revision and fencing token. Responses identify authoritative
revision and never rely on prose for lifecycle status.

## Ordering, Retry And Recovery

Session context, wire and task stores keep their own monotonic sequences. A
protocol response may correlate those sequences but cannot invent one total order
across independent stores. Causal references connect an admitted input, task,
tool effect and resulting message.

Safe reads may retry with the same request identity. Mutations may be retried only
with the same idempotency key and expected revision. Timeout means outcome
unknown until an authoritative refresh. A new key is a new operation and requires
new user or scheduler intent.

After runtime loss, the control plane fences the old generation before assigning
a new owner. Persisted running tasks recover as interrupted according to Spec
016. The new runtime rebuilds transient objects from durable intent, never claims
an old process is alive, and resumes only operations whose contracts support it.

## Identity, Authorization And Privacy

Runtime, user, Agent and service identities are distinct principals. Discovery,
content read, input admission, task control, approval and lease ownership are
separate capabilities. Parent/child relations may reduce discovery friction but
do not imply unrestricted transcript access.

Transport encryption and authenticated peer identity are mandatory for remote
operation. Credentials and private keys remain outside session state. List and
heartbeat records contain only bounded metadata. Full prompts, reasoning, file
bodies, tool output and secrets are not broadcast to observers or control-plane
logs.

## Placement And Offline Behavior

Placement considers required capabilities, project/workspace locality, resource
limits, user policy and active lease. It does not move a session merely to balance
load while a mutating task is active. Workspace transfer is a separate explicit
operation with digest, scope and approval contracts.

An isolated machine may continue only while it holds a still-valid lease and its
policy permits disconnected operation. Two partitions must not both mutate. If
safe fencing cannot be proven, the runtime enters `draining/blocked` and performs
no governed mutation until control-plane contact returns.

## Public User Experience

- list authorized sessions and current runtime placement;
- start or stop a headless runtime explicitly;
- attach a read-only or interactive UI and detach without stopping work;
- inspect connection, lease generation, capabilities and event lag;
- request a governed handoff at a safe checkpoint;
- observe disconnected, blocked, interrupted and failed states distinctly;
- cancel or resume through the authoritative task operation.

## Implementation Sequence

1. Freeze protocol envelopes, identities, revisions and fencing semantics.
2. Build an in-process reference server and deterministic transport fixture.
3. Prove UI attach/detach against the current local session stores.
4. Add headless local execution with restart and approval/input waits.
5. Add authenticated remote transport and control-plane placement.
6. Add safe handoff, partition and event-gap recovery.
7. Run protocol, privacy, failover, latency and long-horizon evaluations.

## Acceptance

- 1,000 attach/detach cycles do not change session, Goal, Plan or task state;
- a stale fencing token performs zero durable mutations;
- retrying one mutation with the same idempotency key creates one effect;
- disconnect during every request boundary is recoverable by authoritative
  refresh without blind replay;
- headless and attached runs produce equivalent domain state for the same fixture;
- a lost runtime recovers running tasks as interrupted, never falsely running;
- unauthorized discovery reveals no content and unauthorized content reads
  return no bytes;
- event gap, timeout, blocked, interrupted, cancellation and failure are distinct;
- bounded lists, snapshots, event pages and content reads hold under load;
- no background process, connection or lease remains after deterministic tests.

## Deferred Work

- implementing the distributed or headless runtime in the current objective;
- automatic cross-machine workspace migration;
- multi-writer session mutation;
- peer discovery without configured trust;
- compatibility with experimental protocol versions.
