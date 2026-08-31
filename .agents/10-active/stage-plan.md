# Stage Plan

- Type: progress
- Attention: active
- Status: active
- Scope: coding-agent-reliability
- Tags: stage, plan, coding, evaluation, verification, safety

## Goal

Deliver M20 as an evidence-driven expansion from the accepted M9-M19 coding
baseline, without replacing the completed runtime contracts or creating
parallel session, task, event, checkpoint, workspace, execution, Trace or Eval
stores.

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
11. M19: rollout and performance implementation (complete; final acceptance passed)
12. M20: seven-language evaluation and verification expansion (active)

## Immediate Next Action

Twelve-language semantic indexing and quality gates are complete. Resolve the
missing `lein` and `tsc` toolchains without silently shrinking the matrix, then
pass the complete seven-language offline fixture, judge and cleanup gate. That
gate must pass before exact-model mutation smokes or repeated provider campaigns
begin. DeepSeek and Kimi results remain independent and per-language.

## Stage Gate

A stage is complete only when its own exit criteria, relevant regression tests
and the canonical suite pass. Commit it immediately as one independently
verifiable stage and record the commands, measurements and remaining work.
