# Termini App Server Bridge

Status: complete
Date: 2026-08-28
Roadmap: M8
Decision: 0026

## Goal

Provide an optional Emacs-native control surface for Termini RuntimeSessions
and jobs while keeping both runtimes independently usable and preserving one
authoritative owner for every durable state transition.

## Package Boundary

The user entry point is the repository-root `termini.el`. It loads bridge and
view modules but is not required by `chat.el`. Merely loading either package
does not start the other runtime.

The bridge uses the configured argv directly through `make-process` via the M6
execution backend. It never invokes a shell. The default command is:

```text
termini app-server --listen stdio
```

The executable and complete argv are configurable for local installations and
tests. Process stderr is kept separate from protocol stdout and bounded for
diagnostics. Disconnect and Emacs shutdown close every sidecar opened by the
bridge.

## Client Contract

`chat-termini-client` schema version 1 contains:

- stable local client ID and connection generation;
- transient process and bounded stderr tail;
- created, connecting, ready, disconnected or failed status;
- monotonic request ID;
- partial JSONL input buffer;
- pending request callbacks and completed synchronous responses;
- negotiated protocol version;
- advertised method and event capabilities;
- bounded notifications and notification observers;
- last redacted error.

Process handles, timers and callbacks are never persisted. RuntimeSession,
message, job and attachment projections are not persisted by this contract.

## Initialization And Capabilities

The bridge supports App Server protocol `2026-07-08`. Initialization sends:

- client name `chat.el` and the local package version;
- the supported protocol version list;
- event subscriptions for job start, completion, failure and log delta.

A connection becomes ready only when:

- the negotiated version equals one offered version;
- the server identifies itself as Termini;
- capabilities contain `initialize`, `shutdown`, `session/list`,
  `session/open`, `command/run`, `message/list`, `job/list`, `job/tail` and
  `job/cancel`.

`message/send`, `attachment/stage`, `attachment/read` and
`attachment/discard` are optional wrappers and fail locally before dispatch
when not advertised. Unknown extra methods and events are retained only as
bounded diagnostic names.

## JSON-RPC Lifecycle

Requests use JSON-RPC 2.0 objects and numeric IDs. The stream parser accepts
arbitrary chunk boundaries, multiple lines in one chunk and blank lines. One
malformed line records a bounded protocol error and does not reinterpret later
bytes as part of that message.

Responses may arrive in any request-ID order. A response completes only the
matching pending request. Duplicate or unknown response IDs are diagnostics;
they never invoke another callback. Notifications omit IDs and go to observers
after their method and bounded params are recorded.

Domain errors preserve the numeric JSON-RPC code, human message and stable
`data.appCode`. Credentials, raw environment values, broad paths and unbounded
payloads are removed from durable diagnostics and user-facing conditions.

Synchronous calls wait for only their response with a finite timeout.
Asynchronous calls own a cancellable timer. Timeout removes the pending request
but does not claim the server did or did not perform the operation.

## Reconnect And Idempotency

Disconnect closes the sidecar connection, not Termini jobs. A process exit:

- fails every pending request once;
- cancels its timers;
- marks the client disconnected or failed;
- never changes a remote job projection to terminal.

Reconnect creates a new sidecar generation, initializes it and discards stale
transient responses and notifications. It never replays a previous request.
The caller refreshes `session/list`, `message/list`, `job/list` and `job/tail`
to recover authoritative state.

`command/run` requires a caller-generated numeric `clientMessageId`.
`message/send` requires a caller-generated string `clientMessageId`.
`job/cancel` uses a caller-generated `clientRequestId`. The bridge can generate
these IDs once for an explicit operation, but it never generates a second ID
to retry the same operation automatically.

Cancellation conflict means the remote job may already be terminal. The UI
refreshes `job/list`; it does not continue to display a locally invented
`cancelling` state.

## Runtime Projections

The bridge validates and exposes bounded records for:

- RuntimeSessions: ID, display name, cwd, project, activity and active-job
  summaries returned by `session/list`;
- messages: ID, role, text, timestamp, content format, content category,
  work kind and attachment references returned by `message/list`;
- jobs: ID, RuntimeSession ID, kind, tool, authoritative status, bounded command
  preview, timestamps, duration, exit code and failure reason;
- job tails: ID, bounded text, truncation, opaque cursor and status;
- attachments: ID, file name, kind, MIME type and byte size.

Remote paths are display-only bounded strings. Attachment bytes are decoded
only after the declared and encoded sizes fit configured limits. Reading an
attachment returns bytes to the explicit caller and does not silently copy them
into chat attachment storage or session history.

## Local Session Binding

`termini-bind-session` stores `termini-runtime-session-id` in one explicit local
`chat-session` metadata record and saves that session. The binding can be
cleared without changing either runtime's conversation history. All operations
also accept an explicit RuntimeSession ID so `termini.el` remains useful
without a chat buffer.

No remote job becomes a durable local `chat-task`. Views are projections over
fresh App Server reads. Notifications may request a refresh, but reconnect
always re-reads durable remote state before presenting completion.

## Native UI

The session view lists RuntimeSession ID, display name, cwd, project, active
job count and last activity. Commands refresh, create, open/bind and show
details.

The job view is scoped to one RuntimeSession and lists job ID, tool, status,
duration, exit code and bounded command preview. Commands refresh, open a tail,
follow, cancel and show details. Terminal states are not offered cancellation.

The attachment commands stage a local absolute file, inspect or save a bounded
read and discard a staged item. They remain unavailable when capability
negotiation did not advertise the corresponding method.

## Public Operations

- connect, disconnect, reconnect and inspect capabilities;
- generic synchronous and asynchronous protocol calls;
- list, create and open RuntimeSessions;
- bind or unbind one local chat session;
- run a Termini command or send a plain message;
- list messages and project attachment references;
- list, tail, follow and cancel jobs;
- stage, read and discard attachments;
- open session and job views.

## Acceptance

- loading `chat.el` alone neither loads `termini.el` nor starts a sidecar;
- initialization fails closed on an incompatible version or missing required
  method;
- split, coalesced, blank and malformed JSONL input remains deterministic;
- out-of-order, duplicate and unknown response IDs cannot cross callbacks;
- pending requests fail once on disconnect and leave no timer behind;
- reconnect never replays a mutating request or invents terminal job state;
- every command, message and cancellation has a stable caller correlation ID;
- cancellation conflict causes an authoritative job refresh;
- optional attachment calls are capability-gated and byte-bounded;
- session binding persists only the remote RuntimeSession ID;
- remote jobs never become a second durable local task store;
- views read through public bridge operations and do not parse Termini files;
- all protocol diagnostics and exports remain bounded and secret-free;
- deterministic offline fixtures pass without a Termini executable;
- opt-in live handshake can run in the foreground and cleanly shut down;
- the canonical suite passes with zero unexpected results.

## Verification

Deterministic protocol and view fixtures cover framing, correlation, duplicate
responses, notification identity, capability negotiation, disconnect cleanup,
idempotency fields, job status validation, cancellation conflict refresh,
bounded attachments and stderr, explicit follow, local session binding and the
optional package boundary.

An opt-in foreground smoke used the installed executable to negotiate protocol
`2026-07-08`, enter `ready`, read five RuntimeSessions through `session/list`,
send `shutdown` and exit without a residual App Server process. The canonical
suite passes 1539/1539 with zero unexpected results.
