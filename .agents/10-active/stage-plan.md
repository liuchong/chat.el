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
- current canonical verification at 1666/1666

## Active Stages

1. M9: isolated real coding Eval baseline (complete)
2. M10: runtime-owned file read set and stale-write refusal (complete)
3. M11: semantic code-intelligence facade and deterministic repo map (complete)
4. M12: project verification plans and bounded repair (complete)
5. M13: structured work context, scoped instructions and working notes (complete)
6. M14: durable TODO plans and native chat progress UI (complete)
7. M15: capability-tested execution isolation backends (complete)
8. M16: read-only Review Agent and conflict-safe coding subagents (active)
9. M17: rollout, performance verification and final acceptance

## Immediate Next Action

Implement M16's independent read-only Review Agent first, then add child coding
roles with declared paths, scheduler resources, session-owned worktrees and a
conflict-refusing merge gate. Reuse M12 verification, M14 plans and M15 execution
policies; do not introduce parallel task, event, checkpoint or workspace stores.

## Stage Gate

A stage is complete only when its own exit criteria, relevant regression tests
and the canonical suite pass. Commit it immediately as one independently
verifiable stage and record the commands, measurements and remaining work.
