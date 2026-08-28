# 0031 - Runtime Status and Strict Coding Acceptance

- Type: decision
- Attention: reference
- Status: accepted
- Scope: coding-agent
- Tags: status, diagnostics, repo-map, performance, evaluation, acceptance

## Context

The coding runtime already had durable plans, verification, repair, review and
isolation facts, but the unified chat surface did not project them as one stable
phase.  Errors often named a failure without a next action.  The repository
map's refresh called itself incremental while still traversing the entire tree
to discover one editor-observed write.  Performance and live Eval results also
lacked one strict final gate that could distinguish failure from missing
evidence.

## Decision

The chat surface projects six runtime phases: `planning`, `understanding`,
`editing`, `verifying`, `repairing` and `reviewing`.  Projection is derived UI
state, not a second lifecycle store.  Repainting preserves input-relative point
and every visible window anchor, and repeated stream chunks do not repaint an
unchanged phase.  The durable plan keeps its native region instead of being
duplicated into the top status line.

Runtime diagnostics use the closed kinds `unavailable`, `blocked`, `stale`,
`failed`, `timeout` and `cancelled`.  Every visible diagnostic includes a next
action appropriate to stale files, semantic capability, verification,
isolation, permission or cancellation.

The repo map keeps stem and importer indexes after a full scan.  Unknown
external changes still use a bounded full refresh; successful precise file tool
calls notify an atomic known-path update that rebuilds only affected relations.
Both paths keep the last complete revision readable while work is pending.

Final coding acceptance remains in the existing immutable Eval store.  One
typed gate set combines the 10,000-file benchmark with compatible M9 and M19
live results.  Any failed gate makes the result failed; otherwise any missing
gate makes it blocked.  Missing baseline, usage or large-repository evidence is
never converted to zero, success or an estimate.

## Compatibility

Older indexing commands remain compatibility entry points while callers move
to the semantic facade and repo map.  They may be removed only after no public
documentation, key binding, configuration example or call site refers to them,
and after one compatibility cycle has recorded that removal condition.

## Consequences

Status is stable during streaming, errors are retryable without reading source,
and a known single-file update no longer scales with repository size.  A final
acceptance record can be reproduced from a clean checkout, but M19 cannot be
marked complete until both 30-task configurations have five compatible trials
per task and a fixed large-repository token fixture exists.
