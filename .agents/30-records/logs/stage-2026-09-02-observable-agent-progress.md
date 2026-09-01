# Observable Agent Progress

- Type: stage-record
- Attention: active
- Status: implementation-verified
- Scope: provider-neutral no-progress accounting during M20
- Date: 2026-09-02

## Follow-up Incident

The first stagnation repair correctly bounded inspection churn after an explicit
tool error, but a later exact `kimi-code/k3-256k` M20 current campaign exposed a
second path. Trial `zig-refactor#4` reached the 300-second outer timeout with 61
model requests and 63 successful tool calls. It recorded one stagnation warning,
then a direct replacement call, then continued reading without a mutation,
recovery event or stop event. The final diff was empty and cleanup was correct.

The campaign was interrupted after the repeated system defect was classified.
Its 168 durable trial records are incident evidence only. It must not be resumed
or aggregated into final M20 acceptance.

## Disproved Assumptions

Two assumptions in the first repair were too weak:

1. A successful tool with write access was treated as progress without checking
   whether any target changed.
2. A repeated same-target inspection could warn without ever starting a bounded
   stop window unless an explicit tool error occurred first.

The focused ten-trial control at the earlier revision showed that ordinary work
was not disturbed. It did not prove every stochastic stagnation path absent.
Passing controls and an unreproduced historical path therefore cannot replace
continued observation in the full campaign.

## Corrected Contract

1. Checkpoint ownership compares every precise direct-file write with the path's
   immediately preceding captured or owned state.
2. A call reports `changed`, `unchanged` or `untracked` before its post-state is
   committed. This preserves the difference between a new mutation and a no-op
   repeated after an earlier mutation.
3. Only `changed` direct writes count as semantic progress. `unchanged` writes
   are inspections and cannot clear recovery guidance.
4. Repeated same-target inspection still warns at six calls. Once any stagnation
   warning exists, twelve further inspections without observable mutation or
   successful verification stop the Run explicitly.
5. Distinct inspection targets before a warning remain valid research. Opaque
   tools without precise path ownership retain conservative accounting.
6. A stop reason is terminal within the Run; a later item in the same completed
   tool batch cannot erase it.

These rules remain provider-, model-, language- and prompt-independent. Model
adaptation may tune prompts only after the common invariant is proven.

## Deterministic Evidence

- Focused Progress and Checkpoint files: 16/16 passed.
- Agent, Checkpoint, Changed Files and Eval files: 163/163 passed.
- Canonical suite: 2039/2039 passed with zero unexpected results.
- Checkpoint regression observes `changed -> unchanged -> changed` across three
  writes to one owned path.
- Loop regressions cover warning, no-op write, varied inspection churn, bounded
  stop, real-mutation recovery and terminal-stop persistence.
- The async Agent integration confirms ordered status propagation from tool
  completion into semantic classification.

## Remaining Gate

Run the canonical suite, freeze and push the corrected revision, then repeat the
exact Zig refactor control five times on `deepseek/deepseek-v4-flash` and five
times on `kimi-code/k3-256k`. Only after both controls pass may fresh current M20
campaigns use this revision. Final acceptance still requires all four immutable
42-task x 5-repetition campaigns and provider-separated aggregation.
