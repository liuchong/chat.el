# Stage - Programming Evaluation Expansion (2026-08-30)

- Type: logs
- Attention: records
- Status: active
- Scope: programming-evaluation
- Tags: evaluation, languages, acceptance, performance

## Scope

This stage records the accepted expansion of the reusable programming Eval
corpus. It does not implement or run the extended live campaign. M19 keeps its
fixed 30-task comparison; M20 adds an independently versioned 42-task language
qualification manifest.

## Accepted Matrix

The core matrix remains Emacs Lisp, Python, JavaScript, Go and Rust. The
extension adds Zig, Clojure, Java, TypeScript, C, C++ and SQL. Every language has
the same six task categories, producing 72 reusable tasks across 12 languages.

The repository now records the durable asset contract in
`specs/028-programming-evaluation-corpus.md`: fixture shape, task wording,
deterministic judges, path boundaries, cleanup, repeated live qualification,
result retention and promotion of language-specific rules.

The reusable operator layer is now committed beside the fixtures:

- `language-registry.json` is the machine-readable 12-language inventory and
  distinguishes the executable core from the planned extension;
- `ACCEPTANCE.md` keeps the smoke cases, representative project fragments,
  execution sequence, cleanup checklist and standard verdict wording;
- `.agents/templates/programming-evaluation-record-template.md` keeps future
  campaign identity, language/category results, performance and failure
  analysis comparable.

An ERT contract checks unique language IDs, 5+7 cohort balance, six categories,
30+42 expected tasks, state boundaries and exact core-manifest language parity.

## Local Toolchain Survey

The bounded preflight survey found:

| Toolchain | Observed local capability |
|---|---|
| Zig | `zig 0.16.0` |
| Java | OpenJDK and `javac 21.0.12.1` |
| TypeScript runtime | Node `26.7.0`; no standalone `tsc` found |
| C and C++ | Apple Clang `21.0.0` |
| SQL | SQLite `3.51.0` |
| Clojure | Leiningen `2.9.4`; no `clojure` or `clj` command found |

This survey is not a permanent minimum-version declaration. Every campaign must
record its own exact executable and version. In particular, Node's ability to
execute stripped TypeScript is not accepted as type checking; the TypeScript
qualification blocks until a local compiler passes preflight. Clojure fixtures
must prove that all dependencies are already available without network access.

## Cleanup Decision

Build and test output is temporary trial evidence. Every writing command has a
declared local output root, and the runner must remove it after the trial before
removing the copied workspace. Repeated integration tests compare status and
disk use before setup and after cleanup. Shared user caches are neither output
targets nor cleanup targets.

This keeps expanded language coverage from growing persistent `target`, class,
binary, cache or database output across campaigns.

## Next Work

1. Finish and freeze the M19 core comparison revision.
2. Add extended-manifest schema and balance tests.
3. Implement seven fixtures and six tasks per language in reviewable batches.
4. Extend detection, verification and semantic quality records from observed
   fixture requirements.
5. Pass offline repeated cleanup before the first provider call.
6. Run one focused mutation smoke per language, then baseline/current repeated
   campaigns without mixing results with the core manifest.

## Core Campaign Evidence

The clean `54db3f1` DeepSeek v4 Flash current campaign completed all 150 core
trials. Each of the five languages passed 30/30 and each of the six categories
passed 25/25. No task changed an out-of-scope path. Twenty standard generated
outputs were declared, audited and removed. The matching deterministic records
passed all 9 runtime gates, all 20 quality gates and 1859/1859 canonical tests.

The paired frozen M9 campaign produced two complete repetitions at 2/30 and
1/30 before the third repetition exposed an inadmissible infrastructure result.
Its dominant valid failure was the old approval path refusing source mutation;
read-only failures were separate answer-quality failures. The campaign stopped
at 64 durable records and is incident evidence only.

## Harness Independence Lesson

A campaign shared across historical implementations cannot unconditionally
call a helper introduced after the baseline revision. The code 18 incident did
not reach the campaign's independent curl-status table because the preceding
Agent transient classifier was undefined in M9. Campaign-level availability
classification now checks whether that optional helper exists, while its own
bounded transport and provider rules remain complete. Regression coverage runs
the code 16 and code 18 cases with the Agent helper absent.

This is an acceptance-integrity rule: infrastructure failures are quarantined
before they claim a repetition/task identity. A campaign containing such a
formal result is invalid even when the remaining samples are useful diagnostics.
After a harness revision changes, both comparison roles receive fresh campaign
identities; partial directories are never rewritten or mixed into the final
aggregate.

## Final Core Acceptance Record

The strict paired aggregate at harness revision
`f0b0701416aaccc54edbac1642886b51f1548d91` used DeepSeek
`deepseek-v4-flash`, manifest digest
`0164487205a6fab51be67eebdfb9d7dad48ec7c68ccadb20b513c2da5e344dcc`
and these immutable campaigns:

| Role | Campaign | Implementation | Passed |
|---|---|---|---:|
| baseline | `m9-baseline-deepseek-v4-flash-e4e6cbc-f0b0701` | `e4e6cbcec89a8a0d5f67d15a861ace9d9b4965d3` | 17/150 |
| current | `m19-current-deepseek-v4-flash-f0b0701` | `f0b0701416aaccc54edbac1642886b51f1548d91` | 150/150 |

Current language results were 30/30 for Emacs Lisp, Go, JavaScript, Python and
Rust. Current category results were 25/25 for locate/explain, single-file fix,
multi-file change, refactor, failing-test fix and read-only review. The baseline
language pass counts were 0, 3, 8, 2 and 4 respectively; its category pass
counts were 10 locate/explain, 7 read-only review and zero for every mutation
category. Current out-of-scope writes and cleanup failures were both zero.

Three current curl code 18 attempts were quarantined and later resumed. They did
not claim formal trial identities. The baseline produced no infrastructure
attempt. Raw campaign storage remains outside Git; both bounded result
directories were under 1 MiB after completion.

Deterministic evidence for the clean current revision passed 9/9 runtime gates,
20/20 quality gates and 1859/1859 canonical tests. Semantic definition,
reference precision/recall and top-five rates were all 1.0. Review recall was
1.0 and precision 0.875. The 10,000-file benchmark measured a 29.388 ms maximum
main-loop slice, 122.949 ms warm-query p95 and 1 ms incremental update.

The final result `eval-20260830T024330654360000-2acb4f` is **failed**, not
accepted. Final-request input-token median was 9,223 for baseline and 12,242 for
current, exceeding the current <= baseline * 1.10 gate. The large-repository
token gate was blocked because all five baseline `python-locate` trials failed,
while the gate currently admits only passed trials. A separate wire-log audit
found first-request medians of 1,921.5 and 5,413.5 tokens. This rules out the
explanation that only longer successful tool loops caused the regression; fixed
resident prompt and tool-schema cost is the next optimization target.

Standard verdict:

```text
FAIL: the paired f0b0701 campaign is complete and current correctness is 150/150, but live-eval-input-token-budget failed and live-eval-large-repo-token-budget is blocked; reduce fixed context cost and rerun both immutable roles.
```
