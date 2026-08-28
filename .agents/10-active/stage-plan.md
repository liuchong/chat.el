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

Produce the missing comparable M19 live evidence: use the provider/model and
fixed manifest identity frozen by the completed M9 baseline, create one fresh
immutable `current` campaign, run M19 over all 30 tasks five times, then record
the strict immutable paired aggregate. The current campaign must have one clean
implementation revision, one manifest digest, 150 results and a terminal
completion record. If its process is interrupted, resume that exact campaign
with `chat-coding-eval-resume-live`; never mix the earlier 30/150 attempt bound
to revision `8c45301` into the new result set. The corpus includes a versioned
task with 10,000 measured indexed files. Do not mark M19 complete while the
current campaign or its trusted token sample is absent.

## Stage Gate

A stage is complete only when its own exit criteria, relevant regression tests
and the canonical suite pass. Commit it immediately as one independently
verifiable stage and record the commands, measurements and remaining work.
