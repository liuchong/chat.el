# Stage Plan

- Type: progress
- Attention: active
- Status: active
- Scope: coding-agent-reliability
- Tags: stage, plan, coding, evaluation, verification, safety

## Goal

Deliver M9-M17 as an evidence-driven improvement of coding task success,
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

1. M9: isolated real coding Eval infrastructure (complete; live baseline missing)
2. M10: runtime-owned file read set and stale-write refusal (complete)
3. M11: semantic code-intelligence facade and deterministic repo map (complete)
4. M12: project verification plans and bounded repair (complete)
5. M13: structured work context, scoped instructions and working notes (complete)
6. M14: durable TODO plans and native chat progress UI (complete)
7. M15: capability-tested execution isolation backends (complete)
8. M16: read-only Review Agent and conflict-safe coding subagents (complete)
9. M17: rollout and performance implementation (complete; final acceptance blocked)

## Immediate Next Action

Produce the missing comparable live evidence: freeze one
provider/model/capability identity, create separate immutable `baseline` and
`current` campaigns, run both M9 and M17 over the fixed 30 tasks five times,
then record the strict immutable aggregate result. Each campaign must have one
clean implementation revision, one manifest digest, 150 results and a terminal
completion record. The corpus includes a versioned task with 10,000 measured
indexed files. Do not mark M17 complete while either campaign or its trusted
token sample is absent.

## Stage Gate

A stage is complete only when its own exit criteria, relevant regression tests
and the canonical suite pass. Commit it immediately as one independently
verifiable stage and record the commands, measurements and remaining work.
