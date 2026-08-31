# Verification Fallback And Structured Task Outcomes

- Date: 2026-09-01
- Scope: M20 focused C control and M21 cross-provider diagnosis
- Status: focused control complete; broader language and provider matrices pending
- Revisions: `aa7f5be`, `14d7492`, `d21d276`
- Manifest: `tests/fixtures/coding-eval/manifest-c-mutation-smoke.json`
- Manifest digest: `3dc5af4afb8f0586148c7a43d39a87f97d1aabbbf3e6915bbadc74d93a705520`

## Problem Sequence

The first C control exposed three connected common-layer defects rather than a
language or provider deficiency.

1. Verification state could inherit the wrong task identity, so a fallback
   decision was not reliably scoped to the child verification task.
2. The ordinary execution menu exposed the generic compile tool before the
   deterministic verification planner had established that no precise adapter
   existed.
3. A successful quiet background command returned only an empty string. The
   Agent could not distinguish completion from a running process and therefore
   polled or reran an unchanged command.

Revision `aa7f5be` isolated verification task identity. Revision `14d7492`
made the precise verification planner the first-stage contract and exposed the
generic compile fallback only after a task-scoped empty plan. Revision
`d21d276` replaced output-only observation with a structured, bounded lifecycle
result.

## Structured Result Contract

`programming_task_output` now returns task identity, status, terminal state,
exit code, bounded output, byte offsets, total byte count, truncation and start
and end timestamps. Byte continuation preserves UTF-8 boundaries. Session
ownership is checked before output is returned, and model-visible results do
not disclose the internal log path.

The decisive rule is explicit: empty output is not running evidence. A quiet
task with `terminal=true`, `status="succeeded"` and `exitCode=0` is complete and
must not be rerun merely because `output=""`.

## Exact-Model Focused Control

Both campaigns used implementation revision
`d21d2760d8a9590a71770ff427dfebe5f81f6d7c`, the same manifest digest and one
`c-failing-test` repetition. Every actual request matched the frozen exact
model identity.

| Metric | DeepSeek | Kimi Code |
|---|---:|---:|
| Campaign | `m20-c-control-deepseek-v4-flash-d21d276-r1` | `m20-c-control-kimi-k3-256k-d21d276-r1` |
| Exact model | `deepseek-v4-flash` | `k3-256k` |
| Trial status | passed | passed |
| Duration | 40,442 ms | 61,424 ms |
| Requests / steps | 14 / 14 | 11 / 11 |
| Tool calls / results | 21 / 21 | 13 / 13 |
| Tool errors | 1 | 1 |
| Approval events | 4 | 6 |
| Total tokens | 147,761 | 57,852 |
| Changed files | `sample.c` | `sample.c` |
| Out-of-scope files | 0 | 0 |
| Workspace cleaned | yes | yes |

Both traces contain exactly one read of the final quiet task result. Each Agent
observed `terminal=true`, `status="succeeded"`, `exitCode=0`, `output=""` and
continued to a final answer without another output poll or verification rerun.

The preceding control on revision `14d7492` provides the counterexample:
DeepSeek used 20 steps and 52.994 seconds; Kimi reached 14 steps and the
120.079-second timeout after repeatedly treating empty output as uncertain and
rerunning verification. A campaign process ending normally did not make that
Kimi trial pass. Persisted trial status and judges are the authority.

## Guard Variability Finding

The same project wrapper command, `sh test-one active`, did not receive the same
model Guard decision. DeepSeek allowed it under the build/test rule; Kimi
abstained and therefore denied it because an arbitrary local script's effects
were not independently known. Kimi then used a direct Clang command and passed.

This is evidence for the existing three-layer direction: deterministic safety
floor, deterministic proven fast path, then model Guard for the unresolved
middle. It is not evidence for allowing arbitrary project scripts. A script can
still mutate project files or perform destructive local actions inside a
network-denied execution boundary. Follow-up work must compare normalized
command provenance and effects, retain fail-closed behavior for unknown
scripts, and measure each provider separately.

## Verification

- work unit tests: 20/20 passed;
- capability unit tests: 36/36 passed;
- work platform integration tests: 2/2 passed;
- canonical suite: 1,972/1,972 passed;
- changed Lisp files byte-compiled successfully;
- generated `.elc` files were removed;
- both focused workspaces and declared generated artifacts were cleaned;
- no campaign-owned process remained after completion.

## Retained Evidence

- `/Users/liu/.chat/evaluations/m20-c-control-d21d276/m20-c-control-deepseek-v4-flash-d21d276-r1`
- `/Users/liu/.chat/evaluations/m20-c-control-d21d276/m20-c-control-kimi-k3-256k-d21d276-r1`

These bounded local results retain trial and request identity. Provider wire
payloads and copied workspaces are not committed.

## Goal-Mode Lessons

This stage also exercises the product's intended long-goal behavior. New user
requirements were recorded without discarding the active M20/M21 sequence;
three systemic defects were fixed and committed independently; each change was
validated before the goal advanced; and the live comparison changed the next
step without rewriting the goal's success criteria.

The reusable rule is that a long-running Goal owns stable purpose and evidence
gates, while its roadmap remains revisioned and responsive to observations.
Incoming non-urgent requirements join the backlog; a repeated or safety-relevant
finding may reorder the next action, but must not silently erase unfinished
work. Checkpoints must retain the current milestone, accepted evidence,
invalidated evidence, open risks and the exact next executable action.

## Verdict

```text
PASS: the exact-model C focused control proves task-scoped verification fallback and structured quiet-task completion on both providers; broader M20 and M21 acceptance remains open.
```

## Remaining Work

1. Apply the quiet-task control to later language mutation smokes.
2. Add provider-separated Guard decision evidence for normalized verification
   commands without widening arbitrary script authority.
3. Continue the remaining M20 language smokes and M21 bounded campaigns; do not
   pool DeepSeek and Kimi results.
