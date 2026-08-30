# Stage Plan

- Type: progress
- Attention: active
- Status: active
- Scope: coding-agent-reliability
- Tags: stage, plan, coding, evaluation, verification, safety

## Goal

Deliver M9-M19 as an evidence-driven improvement of coding task success,
without replacing the completed M0-M8 runtime contracts or creating parallel
session, task, event, checkpoint, workspace, execution, Trace or Eval stores.

The detailed design, construction order, test matrix and acceptance thresholds
are in `programming-capability-reliability-plan.md`.

## Completed Foundation

- M0-M6 lifecycle, capability, extension, task, content and recovery contracts
- M7 attributable memory, derived Trace reconstruction and deterministic evals
- M8 versioned App Server bridge and optional `termini.el` entry point
- current canonical verification is rerun at every stage gate

## Active Stages

1. M9: isolated real coding Eval infrastructure and live baseline (complete)
2. M10: runtime-owned file read set and stale-write refusal (complete)
3. M11: semantic code-intelligence facade and deterministic repo map (complete)
4. M12: project verification plans and bounded repair (complete)
5. M13: structured work context, scoped instructions and working notes (complete)
6. M14: durable TODO plans and native chat progress UI (complete)
7. M15: capability-tested execution isolation backends (complete)
8. M16: read-only Review Agent and conflict-safe coding subagents (complete)
9. M17: durable cross-turn Goal state machine (complete)
10. M18: read-only Plan Mode and exact-revision approval (complete)
11. M19: rollout and performance implementation (complete; final acceptance blocked)

## Immediate Next Action

Reduce the fixed resident prompt and tool-schema cost exposed by the completed
`f0b0701` paired campaign. Preserve the current 150/150 correctness result while
bringing median trusted input tokens to at most 110 percent of the frozen M9
baseline. Measure first-request and final-request usage separately so startup
context cost cannot be confused with longer successful tool loops. Define a
valid large-repository comparison when the historical task has trusted usage
but does not pass; do not weaken the 15 percent reduction target or rewrite the
immutable campaign. After implementation, commit a clean revision, rebuild the
runtime/quality/canonical records and run fresh baseline/current 30-by-5
campaigns. Do not mark M19 complete until both token gates pass.

## Stage Gate

A stage is complete only when its own exit criteria, relevant regression tests
and the canonical suite pass. Commit it immediately as one independently
verifiable stage and record the commands, measurements and remaining work.
