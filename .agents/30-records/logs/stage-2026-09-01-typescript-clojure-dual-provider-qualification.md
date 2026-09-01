# TypeScript and Clojure Dual-Provider Qualification

- Type: stage-record
- Attention: reference
- Status: complete
- Scope: M20 focused mutation qualification
- Date: 2026-09-01

## Outcome

TypeScript and Clojure now pass their focused failing-test mutation task on
both exact qualification models. This closes all seven per-language focused
cells and permits the complete repeated 42-task campaigns to start.

All four campaigns ran from clean revision
`c05ed64d5bd13db48a823194ae9d66c8a788b0e6`, used role `current`, one task and
one repetition, and produced immutable completion records with `1/1` passed.

## Campaign Evidence

| Language | Provider / model | Duration | Requests / steps | Tool calls / errors | Configuration digest |
| --- | --- | ---: | ---: | ---: | --- |
| TypeScript | DeepSeek `deepseek-v4-flash` | 27.298 s | 11 / 11 | 19 / 0 | `fa7028f9933d16e1028a747b935784bdedda40b70413b6b6b68418a622225770` |
| TypeScript | Kimi Code `k3-256k` | 73.696 s | 8 / 8 | 10 / 0 | `ba12bd3b291024ce37c6b9e7c3c7622953bebcac92e7f3b5e6d45ad607db1125` |
| Clojure | DeepSeek `deepseek-v4-flash` | 46.605 s | 16 / 16 | 26 / 1 | `d6bbd95a3ae69513ce85e3c1ad26649d8c4b94fc6f1a397a9a089d38686800d4` |
| Clojure | Kimi Code `k3-256k` | 98.510 s | 12 / 12 | 14 / 0 | `bc4196bfbab8e744baceb211c43f6e31d87efe24b24b4cdcdbb03704c652716b` |

TypeScript used manifest digest
`963a11428878f82cd38cb96e78c60b92cbaa6648076d773e6d4273e8faa1d784`
and changed only `sample.ts`. Clojure used manifest digest
`fd268973d5c482872a793403349f71c427e2e1ec85d82f053358d303ad4aec92`
and changed only `src/sample/core.clj`.

The TypeScript toolchain record contains Node 26.7.0, shell 3.2.57 and
TypeScript 7.0.2. The Clojure record contains shell 3.2.57 and official Clojure
CLI 1.12.5.1664. No campaign used `k3`, K2.7, an alias, a nested executable or
a downloaded dependency.

## Correctness and Safety

- every executor ended `completed`;
- every exact active test command returned exit code zero;
- every allowed-path check passed;
- stale writes and verification retries were zero;
- each workspace cleanup check passed;
- out-of-scope files and retained generated files were empty;
- the canonical suite passed 2009/2009 with zero skipped and zero unexpected.

The first canonical invocation omitted `/Users/liu/.cargo/bin` from `PATH`, so
two Rust isolation tests were skipped because `rustup` was undiscoverable. The
full suite was rerun with the installed toolchain path declared and passed all
2009 tests. Environment-dependent capability tests must freeze their executable
search path; a skipped gate is neither a product failure nor passing evidence.

The DeepSeek Clojure trial made one denied `files_list` request outside the
allowed directories at step 12. The guard rejected it, the trial recovered,
and the final change remained in scope. This is retained as a bounded model
behavior observation, not promoted into a Clojure rule from one sample.

## Interpretation

These four single-task cells qualify the two newly available toolchains and
close the per-language mutation-smoke gate. They do not establish comparative
latency, cost or model quality, and they do not replace the five-repetition
42-task baseline/current acceptance matrix.

## Next

Freeze separate baseline and current implementation revisions under the same
extended manifest, provider/model identity and observation budget. Run five
repetitions per task for 210 unique results in each campaign, then aggregate by
language before applying the M20 exit thresholds.
