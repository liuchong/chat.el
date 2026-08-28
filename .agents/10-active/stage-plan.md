# Stage Plan

- Type: progress
- Attention: active
- Status: active
- Scope: coding-agent-reliability
- Tags: stage, plan, coding, evaluation, verification, safety

## Goal

Deliver M9-M15 as an evidence-driven improvement of coding task success,
without replacing the completed M0-M8 runtime contracts or creating parallel
session, task, event, checkpoint, workspace, execution, Trace or Eval stores.

The detailed design, construction order, test matrix and acceptance thresholds
are in `programming-capability-reliability-plan.md`.

## Completed Foundation

- M0-M6 lifecycle, capability, extension, task, content and recovery contracts
- M7 attributable memory, derived Trace reconstruction and deterministic evals
- M8 versioned App Server bridge and optional `termini.el` entry point
- current canonical verification at 1567/1567

## Active Stages

1. M9: isolated real coding Eval baseline
2. M10: runtime-owned file read set and stale-write refusal
3. M11: semantic code-intelligence facade and deterministic repo map
4. M12: project verification plans and bounded repair
5. M13: capability-tested execution isolation backends
6. M14: read-only Review Agent and conflict-safe coding subagents
7. M15: rollout, performance verification and final acceptance

## Immediate Next Action

Start M9 by freezing the 30-task manifest contract, fixture ownership rules,
deterministic judges and immutable result projection before running a model.
No later default may be enabled until its effect is measurable against that
baseline.

## Stage Gate

A stage is complete only when its own exit criteria, relevant regression tests
and the canonical suite pass. Commit it immediately as one independently
verifiable stage and record the commands, measurements and remaining work.
