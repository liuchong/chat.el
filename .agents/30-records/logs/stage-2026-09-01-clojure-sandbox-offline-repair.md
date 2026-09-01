# Clojure Sandbox Offline Repair

- Type: stage-record
- Attention: reference
- Status: complete
- Scope: M20 evaluation infrastructure repair
- Date: 2026-09-01
- Implementation revision: `f3c419074ac93537ac25b26095f1c7017bb5bf66`

## Incident

The first 42-task development campaign
`m20-dev-baseline-deepseek-c05ed64-r3` was stopped after
`coding/clojure-multi-file` ended `work-plan-blocked`. Its exact judge ran twice
and both attempts failed while resolving the Maven descriptor for
`org.clojure:clojure:1.12.5`.

This was an infrastructure failure, not a model correctness result. Host-side
preflight could see the developer Maven cache, while the Darwin build sandbox
correctly denied that cache and network access. The interrupted campaign is
retained only as incident evidence. It cannot be resumed or mixed with the
revised fixture contract.

## Repair

The fixture still uses only the official `clojure` CLI. Its runner reads the
CLI installation directory through `clojure -Sdescribe`, requires exactly one
bundled `clojure-tools` jar and binds `org.clojure/clojure` to that local jar
through `-Sdeps`. It does not grant access to user caches or the network, add a
second toolchain, or introduce an undeclared executable.

The six stable Clojure task IDs moved to revision 3 and fixture identity
`clojure-sample-v3`. The combined and focused mutation manifests use the same
canonical task records. The complete 42-task manifest digest is
`fecacb185cd4b2d95c30f8fd62ff1e21ecae28731628fcf0045499390c7e0de0`.

## Clean Revision Evidence

Both 42-task, three-repetition no-network descriptors passed on the clean
implementation and harness revision above:

| Provider / model | Configuration digest | Expected trials |
| --- | --- | ---: |
| DeepSeek `deepseek-v4-flash` | `c4f5d70c4b52a41b4c4d789514e23d9d34c337e765e49a520087532de170795a` | 126 |
| Kimi Code `k3-256k` | `d5c1d9ed12106cbc1195e53f5fce950e6f3b0e18fb8745824e59e524a85a4369` | 126 |

The revised focused manifest digest is
`36e49884780bf594797c3636a2324a1448ef1ae9733407a7c73245c4264e232e`.
Its exact-model live results are:

| Provider / model | Duration | Requests / steps | Tool calls / errors | Configuration digest |
| --- | ---: | ---: | ---: | --- |
| DeepSeek `deepseek-v4-flash` | 28.459 s | 13 / 13 | 19 / 0 | `95d123b17790017cc24f4ec3c86a2e6c45f4e47d740b872d4f57637142d68859` |
| Kimi Code `k3-256k` | 77.898 s | 8 / 8 | 8 / 0 | `a7a8195ffa561bfd84d26e25903d0dba12f790664dfa8dcbc93b384db19511ce` |

Both results passed executor status, allowed paths, exact `active` judge and
workspace cleanup. Each changed only `src/sample/core.clj`; tool errors,
out-of-scope files, stale writes and verification retries were zero. Generated
`.cpcache` evidence was declared and removed with the copied workspace.

## Verification

- real Darwin build-sandbox Clojure regression: 1/1 passed;
- focused manifest identity and official CLI contract tests: 3/3 passed;
- all-seven fixture baseline and seeded-defect gate: 7/7 passed;
- clean-revision campaign preflight: 2/2 exact providers passed;
- clean-revision canonical suite: 2010/2010 passed, zero skipped and unexpected;
- repository fixture build artifacts and surviving campaign processes: zero.

## Replayable Lessons

1. Executable discovery, isolated HOME and a host-side offline gate do not prove
   that a real sandbox can resolve the same runtime.
2. A fixture with user-cache or network resolution behavior needs a healthy
   judge regression through the actual isolation backend.
3. Infrastructure failure stops the campaign immediately and remains separate
   from model quality. A changed task contract gets a new revision and fresh
   campaign identity; old trials are never resumed or pooled.
4. Fix the dependency boundary instead of widening filesystem or network
   permissions. Toolchain provenance must include every external executable
   hidden behind a wrapper.

## Next

Start fresh provider-separated 42-task-by-three development campaigns at a
single clean revision. Diagnose any repeated failure before freezing the four
final 42-task-by-five baseline/current campaigns.
