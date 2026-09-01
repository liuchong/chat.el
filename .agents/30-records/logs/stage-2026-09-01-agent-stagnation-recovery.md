# Agent Stagnation Recovery

- Type: stage-record
- Attention: reference
- Status: complete
- Scope: provider-neutral Agent progress recovery discovered during M20
- Date: 2026-09-01

## Incident

Exploratory Kimi campaign `m20-final-current-kimi-28e6757-r1` reached 83 PASS
and one timeout in its first 84 formal results. The timed-out identity was
`zig-single-fix#2`. After one precise `files_patch` no-match error, the Agent
performed 23 further read/search operations without a successful mutation or
verification and reached the 300-second outer timeout. The matching first
repetition passed in 128 seconds with seven requests.

This campaign was stopped when the product contract changed. Its immutable
results are incident evidence only and must not be resumed or aggregated into
final M20 qualification.

## Classification

The failure was semantic stagnation after a recoverable tool error, not a Zig
compiler, fixture, judge or provider availability failure. The repair therefore
belongs to the common Agent loop. It does not branch on provider, model,
language, prompt text or one tool's exact error string.

## System Contract

Revision `4169e73` adds a transient progress state to every Agent run.

1. Successful project mutation or verification is semantic progress and resets
   the inspection sequence.
2. Plan, Goal, note and TODO bookkeeping is neutral; it cannot disguise a lack
   of project progress.
3. After a tool error, six consecutive inspections produce one request-only
   recovery reminder. The reminder is not durable transcript content.
4. Twelve consecutive inspections after the error stop explicitly with a
   stagnation reason before the outer timeout.
5. Detection, recovery and stop counts are normalized Eval evidence.
6. Repeated inspection without a prior tool error may receive the bounded
   reminder but does not hard-stop under this contract.

The thresholds are deterministic product constants, not model-specific tuning.
Changing them requires repeated evidence and a new acceptance comparison.

## Reusable Control

Revision `0805fb7` adds
`tests/fixtures/coding-eval/manifest-zig-single-fix-stagnation-diagnostic.json`.
It is an exact one-task subset of the 42-task extended manifest: task revision,
prompt, allowed paths, generated paths, 300-second budget and judge are equal.
Only the top-level executable preflight is narrowed to `zig`.

The exact-subset ERT passed 1/1. Progress-state and loop regressions cover the
warning, recovery, stop, reset, durable-transcript exclusion and Eval-counter
branches. The full canonical run reported 2019 expected passes, zero unexpected
results and two environment-isolation skips; the canonical runner intentionally
returns nonzero when any test is skipped.

## Dual-Provider Live Control

Both clean-revision focused campaigns used implementation/harness revision
`0805fb79b8a78ea9b3277c7d453b5f13425896cf`, manifest digest
`8167adc14c6df1b99b0d07a66788862e9bc30839f5cb37e57d5156782ea7ebeb`
and five repetitions.

- `m20-stagnation-deepseek-0805fb7-r1`: exact
  `deepseek/deepseek-v4-flash`, 5/5 PASS, 20.754--58.034 seconds, 8--19
  requests. One trial had a tool error and recovered before the six-inspection
  warning threshold.
- `m20-stagnation-kimi-0805fb7-r1`: exact `kimi-code/k3-256k`, 5/5 PASS,
  37.519--139.094 seconds, 6--9 requests, no tool errors.

All ten trials changed only `sample.zig`, passed the exact judge and left no
out-of-scope final file or owned workspace. Detection, recovery and stop counts
were zero, so these runs prove the monitor does not disturb normal completion;
they do not claim a fresh stochastic reproduction of the full stagnation path.
That path is retained by the immutable incident and deterministic tests.

## Next Gate

Freeze a new clean current revision after this record. Recreate all four final
M20 campaigns instead of resuming the exploratory current pair: historical
baseline/current for each exact provider, 42 tasks x 5 repetitions, with the
same manifest and provider-separated acceptance.
