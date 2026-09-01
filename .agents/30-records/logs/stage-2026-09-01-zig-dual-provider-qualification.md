# Zig Dual-Provider Mutation Qualification

Date: 2026-09-01
Revision under test: `69830a4f022020b4fafbf5e934f97e810984c1f4`
Status: Zig focused qualification complete; M20 repeated matrix remains open

## Scope

This stage closes the reusable Zig mutation smoke against both exact provider
identities. It also refreshes the remaining TypeScript and Clojure preflight
state without installing a toolchain or issuing a provider request.

The focused manifest is
`tests/fixtures/coding-eval/manifest-zig-mutation-smoke.json`, with digest
`870c4da24b6456e4e1c382a1485610cd59da55c08a4a6867cc60c997bec7d0ac`.
It contains the canonical Zig failing-test task, allows only `sample.zig`,
declares `.zig-cache` and `zig-out` as generated paths, and uses the exact
`sh test-one active` judge under the shared 300-second correctness window.

## Offline Gate

The bounded fixture command passed with Zig 0.16.0:

```text
PASS: zig fixture baseline and seeded defects are deterministic
```

Both campaign preflights then resolved `/bin/sh` and
`/opt/homebrew/bin/zig`, recorded the same clean implementation/harness
revision and manifest digest, and completed before provider use.

## Independent Live Results

| Provider | Concrete model | Campaign | Config digest | Result | Duration | Requests | Tools | Errors |
| --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| DeepSeek | `deepseek-v4-flash` | `m20-zig-deepseek-69830a4-r1` | `77a8cb8ba1f10cb2e18bfac063c49d0a60c3363b12497048323c37a40c5e7820` | 1/1 PASS | 21,491 ms | 10 | 16 | 0 |
| Kimi Code | `k3-256k` | `m20-zig-kimi-69830a4-r1` | `d9e5e7e4e84759710021034c67f5ca2f776574e71da196a34e6990a4d98b75bd` | 1/1 PASS | 62,160 ms | 7 | 10 | 0 |

Every DeepSeek request recorded `deepseek/deepseek-v4-flash`; every Kimi
request recorded `kimi-code/k3-256k`. Neither trial used an alias or lacked
request identity.

Both trials:

- changed only `sample.zig`;
- passed the deterministic judge;
- recorded zero stale writes and zero out-of-scope files;
- completed their single-step plan decision;
- persisted `source=runtime-contract`, one command and equal ordered-command
  digests with `exactContractMatch=true`;
- bounded the generated-file projection to 256 paths plus an omission marker,
  with 570 additional cache entries omitted from metadata;
- removed the copied workspace and all declared Zig cache/output paths.

The token records were:

| Metric | DeepSeek | Kimi Code |
| --- | ---: | ---: |
| First-request input | 1,556 | 1,197 |
| Final-request input | 11,634 | 6,050 |
| Total-task input | 82,799 | 28,653 |
| Total-task output | 2,140 | 874 |
| Cache read | 39,424 | 6,912 |

This one-task result is a language qualification, not a provider performance
baseline and not evidence for a model-specific policy.

## Remaining Toolchain Blockers

On the same clean revision, focused preflight failed before provider setup or
readiness for:

- TypeScript: `Campaign judge executables are unavailable: tsc`;
- Clojure: `Campaign judge executables are unavailable: lein`.

The installed `npx` command is not an independent offline TypeScript compiler,
and the repository has no accepted project-owned substitute for either missing
executable. The runner correctly produced no trial and no model request. These
states remain infrastructure `BLOCKED`, not skipped tasks or model failures.

Five of seven M20 languages now have independent DeepSeek and Kimi mutation
qualification: Zig, Java, C, C++ and SQL. TypeScript and Clojure remain blocked,
so the 42-task baseline/current repeated matrix is not yet eligible to run.

## Cleanup And Evidence

Repository status remained clean. No `.zig-cache`, `zig-out`, compiled Emacs
artifact, campaign process or test process remained in the repository.

The focused documentation and coding-Eval unit run passed 70/70. It covered
focused-manifest identity, toolchain-before-API ordering, generated-path
boundaries, exact model identity and documented command consistency. The valid
targeted entry point included `tests/unit` on the Emacs load path before loading
`test-helper.el`; two earlier invocations stopped before test discovery because
that load path was incomplete and produced no test or product state.

Runtime evidence is retained outside Git at:

- `/Users/liu/.chat/evaluations/m20-zig-69830a4/m20-zig-deepseek-69830a4-r1`
- `/Users/liu/.chat/evaluations/m20-zig-69830a4/m20-zig-kimi-69830a4-r1`

## Verdicts

```text
PASS: m20-zig-deepseek-69830a4-r1 contains 1/1 unique valid Zig trial at 69830a4; identity, correctness, verification, scope and cleanup gates passed.
PASS: m20-zig-kimi-69830a4-r1 contains 1/1 unique valid Zig trial at 69830a4; identity, correctness, verification, scope and cleanup gates passed.
BLOCKED: TypeScript and Clojure produced no admissible trial because required offline executables were unavailable before provider use.
```
