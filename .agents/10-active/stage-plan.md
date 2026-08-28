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
- current canonical verification at 1615/1615

## Active Stages

1. M9: isolated real coding Eval baseline (complete)
2. M10: runtime-owned file read set and stale-write refusal (complete)
3. M11: semantic code-intelligence facade and deterministic repo map (complete)
4. M12: project verification plans and bounded repair (complete)
5. M13: structured work context, scoped instructions and working notes
6. M14: durable TODO plans and native chat progress UI
7. M15: capability-tested execution isolation backends
8. M16: read-only Review Agent and conflict-safe coding subagents
9. M17: rollout, performance verification and final acceptance

## Immediate Next Action

Start M13 by freezing fragment, note, scope, authority and AGENTS dependency
contracts before changing prompt assembly. M14 consumes that typed projection;
no later default may be enabled until its effect is measurable against M9.

## Stage Gate

A stage is complete only when its own exit criteria, relevant regression tests
and the canonical suite pass. Commit it immediately as one independently
verifiable stage and record the commands, measurements and remaining work.
