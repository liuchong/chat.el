# Extended Eval Time-Budget Correction

- Type: `logs`
- Attention: `records`
- Status: `active`
- Date: 2026-09-01
- Diagnostic revision: `f871308f0b9a7d534399c8560faf9eed4521c624`

## Trigger

The exact-model C++ and SQL focused campaigns used the same clean revision and
the same 120-second task default. DeepSeek completed both tasks; Kimi reached
the deadline without editing, while preserving exact `kimi-code/k3-256k`
request identity and producing no tool error or cleanup residue.

| Language | Provider/model | Result | Seconds | Requests | Tool calls | Tool errors | Tokens |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| C++ | `deepseek/deepseek-v4-flash` | passed | 18.875 | 11 | 19 | 0 | 64,921 |
| C++ | `kimi-code/k3-256k` | timed-out | 120.063 | 8 | 10 | 0 | 28,959 |
| SQL | `deepseek/deepseek-v4-flash` | passed | 32.603 | 12 | 15 | 0 | 98,498 |
| SQL | `kimi-code/k3-256k` | timed-out | 120.080 | 7 | 8 | 0 | 32,323 |

The Kimi runs changed no files and ended only because the evaluator terminated
before `agent-end`. Cleanup passed. Historical exact-model M20 samples include
valid completions at 49.250, 61.424, 62.741, 76.174 and 103.461 seconds, plus
multiple language-independent terminations clustered at 120.05--120.08 seconds.
That shape identifies right-censoring at the shared default, not a C++- or
SQL-specific tool-contract defect.

## Correction

The corpus now owns an explicit `taskTimeoutSeconds` value. Extended and focused
manifests declare 240 seconds, tasks inherit it, and an individual task may only
replace it with its own positive value. Every provider receives the same
correctness observation window. Latency, request count and token use remain
separate measurements; reaching the window still fails the trial. Hidden
provider-specific multipliers are prohibited.

This is a corpus identity change. The manifest digest changes, so the diagnostic
samples above cannot be pooled with the correction rerun.

## TDD Evidence

Before implementation, three focused assertions failed because the extended and
focused manifests exposed no corpus-level task budget. After adding loader
inheritance, positive-value validation, task override coverage and the versioned
manifest fields, all four focused tests passed.

The complete coding Eval unit selector passed 45/45. The canonical suite then
ran 1,980 tests: 1,978 passed, 0 were unexpected and the two known Rust
environment tests were skipped. The canonical runner returned nonzero because
its strict success predicate treats every skip as non-green; no new failure was
introduced.

## Rerun Gate

The record remains active until C++ and SQL are rerun for both exact models on
one clean correction revision and one new manifest digest. The rerun must report
correctness, scope, cleanup, latency, request count, token use and exact request
identity independently.

## Long-Goal Lesson

A long-running goal must let failed evidence modify the execution plan without
silently changing the product claim. Preserve provider identities, classify the
shared measurement boundary first, and improve that explicit boundary before
adding provider prompts or provider-only exceptions. The TODO remains ordered:
correct the versioned contract, verify it offline, commit a clean revision, then
rerun comparable live evidence.
