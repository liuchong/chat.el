# Decision 0022

- Type: decisions
- Attention: reference
- Status: accepted
- Scope: agent-runtime
- Tags: tasks, scheduler, cancellation, recovery, subagents

## Title

Represent every unit of work with one durable task and live adapters

## Context

Foreground agent runs, background commands, declarative workflows and
subagents each had their own status vocabulary, identity and cancellation
path. Only background commands had a standalone durable registry; workflows
lived inside session metadata and subagents lived in memory. A process
sentinel, an agent callback and a user cancellation could also race to close
the same work through different code paths.

Persisting live process objects or callbacks would not solve restart recovery:
those values cannot be reconstructed and treating them as durable would imply
that stale execution can be resumed. Parallel execution also needs one place
to decide which work conflicts over the same resource.

## Decision

`chat-task` version 1 is the canonical work contract. Its states are `queued`,
`running`, `waiting-approval`, `needs-attention`, `completed`, `failed`,
`canceled` and `interrupted`. Terminal transitions are exclusive and
idempotent. Compatibility readers normalize earlier spellings without adding
them to the canonical vocabulary.

The durable record contains identity, parent, kind, status, session,
timestamps, attempts, resource declarations, bounded payload and outcome,
checkpoint, metadata and child policy. Runners, process handles, buffers,
cancellation callbacks and cancellation tokens are live adapter fields and are
never serialized.

The registry is atomically replaced under `~/.chat/tasks/`. Loading a record
that was `running` marks it `interrupted`; it never resurrects the old runner.
A future schema is rejected before any rewrite. The legacy background-task
reader imports a unified copy only after validating the source document and
does not rewrite that source.

The scheduler starts at most `chat-task-max-parallel` tasks. Tasks declare
resource keys with read or write access; equal keys conflict when either side
writes. Priority and stable id make selection deterministic. Parent
cancellation uses an explicit `cancel`, `detach` or `wait` policy.

Foreground UI runs, background processes, workflows and subagents adapt to
this contract. A subagent task is a child of the active agent task, and its
child session records that task as the parent of any further delegated work.
Workflow checkpoints map to waiting or attention states. Existing domain
events remain, while task lifecycle events provide the common projection.

## Consequences

One task tree can inspect and cancel heterogeneous work without learning each
backend's state machine. Restart recovery is honest about what was interrupted,
and M6 can add resumable adapters without weakening that distinction. Parallel
resource safety and terminal idempotence are enforced below the UI.

The initial foreground adapter is enabled by the real chat UI rather than every
low-level kernel invocation, so tests and internal probes do not become user
tasks. Full checkpoint reconstruction and backend relocation remain M6 work.

## Verification

The canonical suite passes 1444/1444. Focused tests cover transition
exclusivity, cancellation idempotence, resource scheduling, parent policies,
stale-run interruption, future schemas, legacy import, foreground tracking,
workflow checkpoints, subagent parentage and native tree/detail projections.
