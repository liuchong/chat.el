# Extended Eval Time-Budget Correction

- Type: `logs`
- Attention: `records`
- Status: `completed`
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
manifests declare 300 seconds, tasks inherit it, and an individual task may only
replace it with its own positive value. Every provider receives the same
correctness observation window. Latency, request count and token use remain
separate measurements; reaching the window still fails the trial. Hidden
provider-specific multipliers are prohibited.

This is a corpus identity change. The manifest digest changes, so the diagnostic
samples above cannot be pooled with the correction rerun.

## First Correction Rerun

Revision `1bda1315733d3cc8886eb50dfd60515690d9c6cf` first tried a 240-second
window. All four exact-model trials passed their judges, scopes and cleanup:

| Language | Provider/model | Seconds | Requests | Tool calls | Tool errors | Tokens |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| C++ | `deepseek/deepseek-v4-flash` | 18.765 | 10 | 17 | 0 | 84,461 |
| C++ | `kimi-code/k3-256k` | 239.652 | 9 | 11 | 0 | 41,284 |
| SQL | `deepseek/deepseek-v4-flash` | 15.110 | 10 | 11 | 0 | 70,290 |
| SQL | `kimi-code/k3-256k` | 101.708 | 8 | 8 | 0 | 28,485 |

Every request retained its declared provider/model identity, C++ changed only
`sample.cpp`, SQL changed only `sample.sql`, and all tool-result counts matched
tool-call counts. The C++ Kimi trial finished only 0.348 seconds before the
window. That pass disproved the old 120-second classification but also showed
that 240 seconds was not a stable correctness boundary: ordinary scheduling or
network jitter could flip the verdict. The shared window was therefore raised
to 300 seconds for all providers before final evidence collection. The
`1bda131` samples remain diagnostic and cannot be pooled with the new digest.

After the 300-second adjustment, the focused selector again passed 45/45 and
the canonical suite again reported 1,978/1,980 passed, 0 unexpected and the same
two known Rust environment skips.

## Final 300-Second Rerun

The final rerun used clean revision
`a4e4e1827b9f514c59f966bfa10a738ad85c3d2e`. C++ used manifest digest
`0680f430312056570099cd842d7c1b4140b52544127bf6be76b4020657021da3`;
SQL used `1494b45ffcdb6c82aeacde4827e1907abb30d0823c82619c40bc653bab7dda92`.

| Language | Provider/model | Seconds | Requests | Tool calls | Tool errors | Tokens |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| C++ | `deepseek/deepseek-v4-flash` | 42.391 | 14 | 23 | 1 | 142,248 |
| C++ | `kimi-code/k3-256k` | 208.408 | 8 | 10 | 0 | 54,632 |
| SQL | `deepseek/deepseek-v4-flash` | 21.224 | 12 | 16 | 0 | 93,033 |
| SQL | `kimi-code/k3-256k` | 188.539 | 11 | 11 | 0 | 45,538 |

All four trials passed deterministic judges, retained exact request identities,
changed only the declared source file and removed their declared generated
paths. C++ produced only `.chat-eval-build/cpp/test_sample`; SQL produced no
generated artifact. Workspace and campaign cleanup both passed.

The C++ DeepSeek trial recovered from one tool error and still passed. The old
result stored only `toolErrorCount`, while its disposable runtime HOME was
correctly removed, so the error cannot honestly be assigned to a tool or root
cause after the fact. This is a diagnostics-contract defect, not evidence for a
provider prompt change. The Eval executor now retains a bounded chronological
`toolErrors` projection with step, tool, stable error type and single-line
summary, plus `toolErrorRecordsTruncated`. Total counts remain exact; arguments,
raw outputs and exception objects are not persisted.

## TDD Evidence

Before implementation, three focused assertions failed because the extended and
focused manifests exposed no corpus-level task budget. After adding loader
inheritance, positive-value validation, task override coverage and the versioned
manifest fields, all four focused tests passed.

The tool-diagnostics assertion then failed against the old executor because the
error count had no accompanying records. After the bounded projection was
implemented, the complete coding Eval selector passed 45/45. The test covers
chronological structure, stable error type, whitespace normalization, summary
length, record-count truncation and an exact total count.

The canonical suite then ran 1,980 tests: 1,978 passed, 0 were unexpected and
the two known Rust environment tests were skipped. The canonical runner returned
nonzero because its strict success predicate treats every skip as non-green; no
new failure was introduced.

## Closeout

The shared-budget correction is complete: both languages passed with both exact
models on one clean revision, with correctness, scope, cleanup, latency,
requests, tokens and request identity reported independently. This closes only
the C++ and SQL focused qualification slice. It does not close the remaining
M20 language smokes or the final repeated extended campaigns.

## Long-Goal Lesson

A long-running goal must let failed evidence modify the execution plan without
silently changing the product claim. Preserve provider identities, classify the
shared measurement boundary first, and improve that explicit boundary before
adding provider prompts or provider-only exceptions. The TODO remains ordered:
correct the versioned contract, verify it offline, commit a clean revision, then
rerun comparable live evidence.

The second lesson is that goal progress needs durable intermediate facts, not
only a final pass/fail counter. The 240-second near-boundary pass changed the
plan before final collection; the final recovered tool error then exposed a
missing evidence field. A useful Goal mode must keep the active objective and
ordered TODO stable while allowing new evidence to insert a bounded repair,
record why the plan changed, and resume the original milestone without treating
the repair as completion of the larger goal.
