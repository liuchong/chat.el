# 0032 - Goal Contract and Plan Permission Boundary

- Type: decision
- Attention: reference
- Status: accepted
- Scope: agent-runtime
- Tags: goal, plan, todo, context, approval, lifecycle

## Context

The runtime already had durable tasks, work plans, scoped notes and a legacy
title/status goal list.  Those records answer different questions.  Treating
them as one object makes task termination look like objective completion,
allows a revised plan to change the definition of success and turns a planning
prompt into an unenforced promise not to write.

Long-running work also needs to survive ordinary turns, context compaction,
session reload and process restart without copying an ever-growing transcript
back into every request.  Completion must be based on resolvable evidence, not
on a model saying that it is done.

## Decision

A Goal is a versioned completion contract.  It owns the objective, success
criteria, stopping condition, scoped evidence and the
`active|paused|blocked|completed|cancelled` lifecycle.  Agent tools may append
progress and links but cannot rewrite the contract.  Every mutation uses an
expected revision, and completion requires every required criterion to resolve
known evidence under the deterministic stopping predicate.

A work plan/TODO is a replaceable execution path.  A Goal may link multiple
plan revisions and runtime tasks; plan or task completion only records progress
and never completes the Goal implicitly.  Work notes remain independently
scoped context rather than becoming Goal fields.

Plan Mode is a separate session permission state.  While active, the execution
boundary permits read-only research and dedicated note, Goal-progress and plan
state tools.  Source writes, command execution and unknown effects fail closed.
Submitting stores the exact plan ID and revision; only an explicit user path can
approve that revision and leave the mode.

All three records use the existing session metadata, event bus, context bundle
and native chat projection.  Prompt text and UI remain bounded derived views,
not additional authorities.

## Consequences

Goal continuity survives compression and restart without conflating history
with active instructions.  Users can pause, resume, block, clear or cancel work
without losing verified progress.  Plan review is enforceably read-only, and a
changed plan cannot inherit approval from an older revision.

The design adds explicit lifecycle and revision handling, but keeps completion,
planning, notes and execution independently testable.  Legacy incomplete goal
writes are rejected; existing title/status records migrate once to paused
contracts that require an explicit verifiable replacement.

Final M19 acceptance treats Goal and Plan Mode invariants as first-class typed
gates.  Missing measurements block acceptance; measured continuity, evidence,
scope, transition, approval, execution or prompt-budget regressions fail it.
The aggregate stores the bounded `runtimeReliability` evidence object instead
of inferring success from the existence of unit tests.
