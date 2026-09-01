# M21 Core V2 Dual-Provider Acceptance

Date: 2026-09-01
Revision under test: `a7baa438f96de8979bd03478f309dd292344903c`
Status: M21 accepted; no provider-specific policy promoted

## Scope

This stage runs the complete 30-task core-v2 manifest independently against the
two exact qualification models. It verifies that the shared reliability layer
closes the earlier correctness gap without provider-specific success rules.

The frozen manifest is `tests/fixtures/coding-eval/manifest.json`, with digest
`c1e4044d913cd0a22ba1858667cac9eaf16db725c114534387ed71b0d8c7d9ac`.
It contains five languages, six task categories per language and one repetition,
for 30 expected results per campaign. Both campaigns used the same 300-second
per-task correctness window and the same clean implementation revision.

The toolchain was Cargo 1.98.0, Emacs 31.1, Go 1.27.0, Node 26.7.0 and Python
3.14.7. An initial local preflight found Cargo missing from the inherited PATH
before any provider request. Repeating preflight with the installed Cargo path
made both campaigns ready. This was an infrastructure attempt and is not a model
trial or model failure.

## Frozen Campaigns

| Provider | Concrete model | Campaign | Configuration digest |
| --- | --- | --- | --- |
| DeepSeek | `deepseek-v4-flash` | `m21-core-v2-deepseek-a7baa43-r1` | `70acabb5873ebb61d8e7f891aa61411660453367f08abe1ad336647cb62e8146` |
| Kimi Code | `k3-256k` | `m21-core-v2-kimi-a7baa43-r1` | `646333d05bc15dc26321a6033a9d2ffe56924361c532e3cf564d82bcc11bd16b` |

DeepSeek recorded 229/229 requests as
`deepseek/deepseek-v4-flash`. Kimi recorded 191/191 requests as
`kimi-code/k3-256k`. No request lacked identity and no alias was used.

## Independent Correctness Results

| Provider | Pass | Elisp | Go | JavaScript | Python | Rust |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| DeepSeek | 30/30 | 6/6 | 6/6 | 6/6 | 6/6 | 6/6 |
| Kimi Code | 30/30 | 6/6 | 6/6 | 6/6 | 6/6 | 6/6 |

Each provider also passed 5/5 in failing-test repair, locate/explain,
multi-file change, read-only review, refactor and single-file fix. Both sides
reported zero failed, cancelled, timed-out, errored or quarantined admissible
trials.

For each provider, all 20 mutation tasks persisted a
`source=runtime-contract` verification profile with equal contract/profile
digests and `exactContractMatch=true`. DeepSeek completed 20/20 work plans.
Kimi completed 25/25 work plans; its five additional plans belonged to
read-only locate/review tasks. Both providers reported:

- zero out-of-scope file changes;
- zero stale writes;
- zero incomplete or blocked final plans;
- zero workspace cleanup failures;
- zero leaked build or test artifacts recorded by the task contracts.

## Latency And Usage

| Metric | DeepSeek | Kimi Code |
| --- | ---: | ---: |
| Minimum duration | 4,773 ms | 16,797 ms |
| Median duration | 15,821 ms | 56,852 ms |
| p95 duration | 31,904 ms | 164,593 ms |
| Maximum duration | 38,238 ms | 227,986 ms |
| Total task duration | 490,188 ms | 2,172,863 ms |
| Model requests | 229 | 191 |
| Tool calls | 299 | 199 |
| Tool errors | 5 | 0 |
| Approvals | 54 | 50 |
| First-request input tokens | 44,079 | 33,343 |
| Final-request input tokens | 244,998 | 155,718 |
| Total-task input tokens | 1,342,576 | 714,412 |
| Total-task output tokens | 51,800 | 25,994 |
| Cache-read tokens | 707,200 | 293,376 |

Kimi's median was 3.593 times DeepSeek's, its p95 was 5.159 times higher and
its total task duration was 4.433 times higher. At the same time Kimi used
16.6% fewer requests, 33.4% fewer tool calls, 46.8% fewer input tokens and
49.8% fewer output tokens. The 300-second shared window was material: Kimi's
slowest passing result took 227.986 seconds and would have been misclassified
by the historical 120-second corpus window.

## Diagnostics

DeepSeek's five tool errors were all recovered within passing trials:

1. one attempt to complete a non-active plan item in Go multi-file;
2. one unavailable verification operation in JavaScript refactor;
3. one directory passed to file grep in Python locate;
4. two Rust multi-file patch calls missing required patch data.

Kimi recorded no tool errors. Its five extra read-only plans occurred in Go
review, JavaScript locate/review and Rust locate/review. Neither observation is
yet a demonstrated cause of the latency difference, and neither has a frozen
candidate policy with same-model A/B evidence.

## Policy Decision

No provider-specific policy is promoted. The common layer now produces equal
correctness and safety results across the two exact models. The remaining
differences concern efficiency and recoverable behavior, but this campaign does
not isolate a reliable adaptation lever or prove that a model-name branch would
improve it.

The DeepSeek error shapes and Kimi read-only planning/latency remain candidate
observations. Any future proposal must declare one bounded lever, run control
and candidate against the same concrete model and manifest, preserve the common
judge and authority contract, and include a removal condition. Until then the
complete generic path remains active for both models.

## Goal-Mode Lessons

This multi-hour stage served as a real long-running Goal exercise:

- the objective and current milestone survived multiple implementation fixes,
  live campaigns, commits and context compression;
- new non-urgent requirements were admitted with stable identity without
  replacing the active atomic step;
- each deterministic repair and provider campaign formed a checkpoint, allowing
  completed branches to remain closed while only missing evidence was pursued;
- paired evidence pinned one implementation revision, manifest digest and exact
  model identity, preventing Goal drift from silently changing the comparison;
- local smoke success did not complete the Goal; completion waited for both
  independent required branches and the explicit M21 exit conditions;
- compact stage records and immutable runtime paths made recovery possible from
  evidence rather than reconstructed conversational memory.

These lessons are reflected in the active Goal contract: checkpoints must be
structured, parallel validation branches stay independently attributable, new
requirements pass through admission, and completion is evidence-driven.

## Final Verification

After the acceptance record and normative updates, the canonical suite
discovered 1,996 tests: 1,994 passed as expected, 0 were unexpected and 2 known
Rust system-SSL isolation cases were skipped. `git diff --check` passed. No
compiled Emacs artifact, campaign process or test process remained in the
repository workspace.

## Retained Evidence

- DeepSeek campaign:
  `/Users/liu/.chat/evaluations/m21-core-v2-a7baa43/m21-core-v2-deepseek-a7baa43-r1`
- Kimi campaign:
  `/Users/liu/.chat/evaluations/m21-core-v2-a7baa43/m21-core-v2-kimi-a7baa43-r1`
- Each directory contains immutable campaign, completion and per-task result
  records. Runtime records remain outside Git because they include request IDs
  and verbose execution metadata; this repository record retains the bounded
  acceptance facts and reproducible identities.

## Verdicts

```text
PASS: m21-core-v2-deepseek-a7baa43-r1 contains 30/30 unique valid trials at a7baa43; exact identity, correctness, verification, scope, plan and cleanup gates passed.
PASS: m21-core-v2-kimi-a7baa43-r1 contains 30/30 unique valid trials at a7baa43; exact identity, correctness, verification, scope, plan and cleanup gates passed.
PASS: M21 closes on the provider-neutral path with no active model-specific adaptation.
```
