# Decision 0026

- Type: decisions
- Attention: reference
- Status: accepted
- Scope: agent-runtime
- Tags: termini, bridge, json-rpc, projections, reconnect

## Title

Bridge Termini through its App Server without duplicating runtime truth

## Context

The local Agent Runtime and Termini own different durable work. `chat.el` owns
its sessions, tasks and lifecycle stream. Termini owns RuntimeSessions, remote
jobs, message records and staged attachments. Treating one store as a writable
copy of the other would make reconnect, cancellation and terminal state
ambiguous.

Termini already exposes a versioned local App Server using JSON-RPC messages
over newline-delimited stdio. Its protocol admits work asynchronously, reports
durable state through list and tail methods and requires clients to recover by
reading that state after reconnect. This is the narrowest stable integration
boundary available to Emacs.

## Decision

`termini.el` is an optional top-level Emacs entry point. Loading `chat.el` does
not load it, start a process or require a Termini executable. Loading and using
`termini.el` starts a managed App Server sidecar only after an explicit command
or API call.

`chat-termini-client` schema version 1 owns one connection's transient protocol
state: process, request sequence, partial input, pending requests, negotiated
version, advertised capabilities and notification observers. It does not own
RuntimeSession, message, job or attachment truth. Those values are validated,
bounded projections returned by the App Server.

Initialization offers the one supported protocol date and subscribes only to
bounded job lifecycle and log-delta events. The response must negotiate the
offered version and advertise every required method before the connection
becomes ready. Optional attachment methods are used only when advertised.

Every request has one correlation ID and one terminal response. Mutating
requests carry caller-generated message or request IDs where the App Server
supports them. A connection failure never automatically replays a mutation.
Reconnect starts a new connection, negotiates again and refreshes durable
remote projections. It does not infer completion from the old process ending.

A local chat session may explicitly store one Termini RuntimeSession ID in its
existing metadata. This binding is navigation and correlation, not a copy of
remote state. Job notifications may refresh views and produce bounded local
lifecycle facts, but they never create or settle durable `chat-task` records.

Attachments remain references until the user explicitly reads one. Stage,
read and discard operations require advertised methods. Read data is bounded
before decoding, secrets are never logged and remote local paths do not enter
session history.

## Consequences

The bridge remains useful as a standalone Emacs control surface and as an
explicit companion to a local chat session. Termini can keep running after the
sidecar disconnects, and Emacs can restart without reconciling two task stores.

The first bridge supports stdio only. Other App Server transports can implement
the same client contract later without changing views or operation wrappers.
Live integration remains opt-in because it depends on a local executable and
private runtime configuration; the canonical suite uses deterministic protocol
fixtures.
