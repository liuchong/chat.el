# 0028 - Durable Work Plans Inside Runtime Tasks

- Type: decision
- Attention: reference
- Status: accepted
- Scope: agent-runtime
- Tags: planning, todo, tasks, ui, evidence

## Context

The task runtime knows that work exists but not the ordered steps an Agent is
following. Prompt-only TODO lists disappear during compaction, cannot enforce a
mutation checkpoint and cannot be reconstructed reliably after restart. UI
progress inferred from prose is similarly unstable.

## Decision

Introduce the versioned work-plan and plan-item contracts in Spec 022. A plan
belongs to one foreground task and session, has optimistic revision and a
single active item, and completes items only with existing runtime evidence.
Substantial coding actions fail closed when `auto` or `required` policy needs a
plan and none exists. Simple audited cases may use enumerated skip reasons.

The chat buffer renders a compact public projection and keeps fold state local.
It never owns plan truth and must preserve input point and user scroll state.

## Consequences

Long tasks gain a recoverable execution outline and explicit blockers without
turning every read-only answer into ceremony. The plan is not a scheduler:
parallel ownership and cancellation remain `chat-task` responsibilities.
