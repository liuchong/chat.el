# Unified Runtime Tasks

Status: implemented
Date: 2026-08-28
Roadmap: M4
Decision: 0022

## Goal

Give every foreground run, background process, workflow and delegated agent a
single durable identity, state machine, cancellation contract and native
inspection surface. Durable intent must remain separate from live execution
objects so restart recovery never pretends a stale process is still running.

## Contract

The task contract owns schedulable lifecycle and parent/child work identity. It
does not own the ordered TODO steps inside a task; those are the versioned
`chat-work-plan` projection defined by Spec 022. A task can exist without a plan
for compatibility, while governed coding actions may require one.

`chat-task` schema version 1 owns:

- stable task and parent ids;
- canonical state and terminal timestamps;
- session, source and task kind;
- priority and read/write resource declarations;
- bounded payload, result, error and checkpoint data;
- explicit child cancellation policy;
- attempt count and adapter metadata.

The state graph is:

```text
queued -> running -> waiting-approval -> running
                  -> needs-attention  -> running
                  -> completed | failed | canceled | interrupted
```

Terminal states cannot change. Repeating the same terminal outcome is safe and
emits no second terminal event. `cancelled`, `succeeded`, `paused`, `stopped`
and earlier adapter names are accepted only at compatibility boundaries.

## Persistence And Recovery

The unified registry is atomically replaced at `~/.chat/tasks/tasks.json`.
Live runners, callbacks, process handles, buffers and cancellation tokens are
excluded from JSON. A persisted running task loads as the terminal state
`interrupted`; later recovery creates new adapter-owned work instead of
resurrecting the stale execution object.

Future schemas fail before mutation. Existing background records are read from
their versioned source and copied into the unified registry after validation;
the source file is not rewritten. Session workflow records remain the detailed
workflow source while the task registry stores their common projection.

## Scheduling

Scheduler-owned queued tasks run up to `chat-task-max-parallel`. A resource is
`(:key TEXT :mode read|write)`. Two tasks conflict when keys match and either
mode is write. Selection is deterministic by descending priority and stable id.

Cancellation tokens call registered callbacks once. Parent cancellation
recursively cancels children by default; adapters may instead declare detach or
wait. A terminal transition schedules the next eligible queued task.

## Adapters

- The real chat UI tracks one foreground agent task per send.
- Background commands retain their established summaries and logs while their
  process lifecycle is owned by the unified scheduler.
- Workflows mirror running, approval, paused, completed and canceled states,
  including a bounded checkpoint.
- In-process and external subagents use their subagent id as task id and attach
  to the active parent task.
- Existing subagent domain events remain available beside common task events.

## Native Views

`M-x chat-task-view-open` opens a compact tree with state, kind, child count and
updated time. `RET` opens a read-only detail projection. `k` cancels through the
owning adapter, `r` resumes recoverable work and `g` refreshes. Workflow actions
load the owning session so restart-time actions update both durable projections.

## Acceptance

- terminal outcomes are exclusive and emitted once;
- cancellation follows explicit parent and adapter policy;
- non-conflicting tasks run in parallel while writes serialize;
- future and legacy schemas have deterministic migration behavior;
- foreground, workflow, process and subagent work appear in one tree;
- no live execution object is serialized.

## Executable Behavior Scenarios

### Background Work Does Not Block The Agent

Given an Agent in session A and a permitted bounded command, when the Agent
calls `work_task_start`, then it receives a durable task identity before the
process reaches a terminal state and may continue its model loop. When the
process finishes, the adapter invokes its completion hook once, the unified
task and process projections agree on the terminal outcome, and session A can
read bounded output through `work_task_output`.

### Background Evidence Is Session Scoped

Given a task owned by session A, when session B calls `work_task_output` with
the observed task ID, then the operation fails without returning any output.
Session A's wire contains correlated task and execution lifecycle events;
session B receives neither those event bodies nor the task log path.

### Agent Observes A Completed Background Result

Given a multi-step Agent response, when one step starts a background command
and a later step reads its result, then the final assistant response can use
the returned output without blocking the first tool call until completion.
The end-to-end test must exercise the registered tools through the normal
Agent/tool-caller path, not by calling the process adapter directly.
