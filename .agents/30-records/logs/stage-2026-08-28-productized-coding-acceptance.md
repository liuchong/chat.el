# Productized Coding Acceptance

- Type: progress
- Attention: records
- Status: blocked
- Scope: M19
- Tags: runtime-status, diagnostics, performance, eval, acceptance

## Implemented

- six-phase runtime status projection on the unified chat surface
- point and window-anchor preservation across repeated status updates
- actionable closed diagnostics for stale files, semantic capability,
  verification, isolation, permission, timeout and cancellation
- persistent repo-map stem/import indexes and known-path incremental refresh
- strict immutable M19 acceptance gates in the existing Eval store
- typed Goal continuity/evidence/scope/prompt and Plan Mode
  mutation/approval/restore gates backed by `runtimeReliability` evidence
- exact 30-by-5 live sample validation, identity comparison, success, scope,
  verification and token gates
- isolated live campaign directories with immutable configuration and terminal
  completion records
- campaign gates that reject mixed roles, manifests, configurations or
  implementation revisions
- resumable live campaigns that validate the frozen descriptor, model-specific
  capability snapshot and every durable repetition/task identity before only
  scheduling missing trials
- exclusive local run locks with stale-process recovery; cancellation stays
  resumable and only a complete unique matrix can create terminal evidence
- closed failure taxonomy: model ability, context omission, tool error,
  verification error, permission block and infrastructure
- standalone 10,000-file benchmark covering cold index, single-file update,
  warm query, context build, heap delta and cleanup
- fixed large-repository live task with deterministic workspace materialization
  and measured indexed-file evidence

## Performance Evidence

Command:

```text
/Users/liu/projects/.agent-tools/capped.sh 1500 emacs -Q -batch -l tests/performance/run-repo-map-benchmark.el
```

Environment: macOS arm64, Emacs 31.1. Fixture digest
`1f80a0492bbdc1d333ab6e8b4c7159518f230a0a431e7b66c71d954be61a6c5d`,
10,000 files and 30 warm repetitions.

- cold index: 15,287.3ms
- single known-file incremental update: 17.3ms, exactly one changed file
- maximum cold or incremental main-loop wall slice: 31.0ms
- warm query p95: 111.3ms
- context build p95: 1.1ms
- measured heap delta: 21,136,997 bytes

All implemented performance gates passed.  The temporary fixture, timers and
repo-map cache entry were removed before completion.

## Verification Evidence

- focused coding Eval and acceptance tests: 26/26 passed
- canonical unit suite: 1701/1701 passed, zero skipped and zero unexpected
- integration: deterministic coding fixtures and work platform passed 2/2;
  two online-provider checks explicitly skipped because credentials are absent
- deterministic end-to-end: 2/2 passed
- built-in offline Eval: 5/5 passed
- Darwin isolation probe: scoped filesystem, controlled network, explicit
  environment, timeout and process-tree cleanup; backend available
- source reader, parenthesis and `git diff --check` checks passed with no
  compiled artifact

## Large-Repository Evidence

The fixed `python-locate` task revision 2 has the `large-repo` tag. Its
versioned generator digest is
`a39472ea1e2cd4810a2416ca435bdc29371580065999ccf24924bee4801581bd`.
Each isolated run materializes 10,001 files, of which 10,000 match the indexed
source corpus. The resulting fixture digest is
`c10e4eb54a654f78c0c2c573cad8715fb9df8c530443b3675a2fbb8f039d04f0`.
Two integration repetitions passed deterministic judging, actual count checks
and workspace cleanup.

## Current Acceptance Evidence

The immutable M9 baseline campaign
`m9-baseline-20260828T180819` completed against implementation revision
`e4e6cbcec89a8a0d5f67d15a861ace9d9b4965d3`, provider `kimi-code`, model `k3`,
the fixed 30-task manifest and five repetitions. Its terminal record contains
all 150 expected results: 3 passed, 107 failed, 23 errored and 17 cancelled.
This is real baseline evidence and must not be rewritten as a synthetic or
successful result.

The completed M19 `current` campaign `m19-current-20260829T022800` ran at
revision `aa4698a` with the same provider, concrete model, manifest and five
repetitions. It contains the exact 150-result matrix: 112 passed, 37 cancelled
and one failed, with no transport or framework errors. This makes the campaign
valid evidence rather than a successful acceptance result.

Strict comparison record `eval-20260828T215245858158000-82dab4` reports a
74.67 percent current success rate, below the required 80 percent floor. It also
reports five out-of-scope temporary files left by cancelled Rust trials. M9
token usage is absent from 10 of 150 baseline results, so its 6.67 percent
missing-usage rate exceeds the five percent limit and blocks token gates. The
sample matrix, campaign isolation, identity, no-regression, improvement and
verification-evidence gates pass. M19 remains incomplete because failed and
blocked gates may not be averaged away.

Acceptance parsing was corrected after this comparison to read JSON-roundtrip
keyword plists, normalize a redundant model field in capability snapshots and
keep generic executor failures and cancellations in the valid model sample.
Allowed approval counts no longer imply a permission block. These changes fix
classification and evidence handling; they do not rewrite either immutable
campaign or raise its measured success rate.

Post-campaign diagnosis on 2026-08-29 found that the Rust cancellations were
not normal model failures. The Darwin sandbox replaced `HOME`, so the rustup
shim could not locate its configured toolchain. The model then spent its
remaining budget on retries and external-path diagnostics. Restricted Rust
commands now receive read-only access to the resolved developer `RUSTUP_HOME`;
the sandbox still uses a managed home, project-only writes and no network.

The same investigation exposed two evaluation and tool-contract problems.
Work-plan tools advertised an opaque JSON string, which caused malformed calls
and unnecessary Plan Mode entry; they now expose a native nested item schema
with required acceptance evidence, while prompt guidance keeps durable TODO
plans separate from read-only Plan Mode. Coding Eval now requires explicit,
non-overlapping `generatedPaths` for build outputs and records those separately
from source changes and out-of-scope files.

A live `rust-refactor` smoke completed in about 27 seconds with status `passed`.
All five checks passed, `src/lib.rs` was the only source change, 118 declared
Rust build outputs were audited separately and the out-of-scope list was empty.
The canonical suite passed 1789/1789. This evidence validates the remediation,
but it is one smoke task rather than the required 30-by-5 comparison.

A first replacement current campaign, `m19-current-20260829T075539`, was
intentionally stopped after 10 of 150 trials when both completed multi-file
tasks cancelled. Eight trials passed. The `go-multi-file` trace showed that the
Agent created a durable plan and began its first item, then could neither encode
nor resolve completion evidence. The provider contract exposed evidence as an
encoded JSON string; successful tool results did not reveal their post-tool
event IDs; and wire events scoped `task_id` to the tool call rather than the
owning Agent task. This was a runtime contract defect, not a transport failure.

Goal and plan progress tools now expose a native string-array `evidence`
parameter. Every successful tracked tool result returns its exact Evidence ID,
while failed tools remain ineligible as completion evidence. Post-tool wire
events preserve the tool-call identity and add `agent_task_id`; the resolver
uses the Agent task scope first and retains the old field only as a compatibility
fallback. Provider schema, Agent feedback, durable resolver and transcript
projection are covered together. The canonical suite passes 1792/1792.

The incomplete campaign remains immutable incident evidence and must never be
resumed after this implementation change. A focused live multi-file smoke must
pass before another 150-trial current campaign is started.

## Unblock Procedure

1. Keep the completed M9 baseline and `aa4698a` current campaign immutable as
   historical evidence; do not append or rewrite either campaign.
2. Commit the Rust runtime, native plan/evidence schemas, scoped Evidence ID
   feedback and generated-output contract, then freeze the resulting
   implementation and manifest revisions.
3. Run fresh 30-by-5 baseline and current campaigns against that exact manifest;
   never resume a campaign across an implementation or manifest revision.
4. Establish trusted token coverage for at least 95 percent of both replacement
   comparison sets. The historical baseline cannot satisfy this gate.
5. Save same-revision `runtimeReliability` measurements, including the Goal
   projection median ratio, then run `chat-coding-acceptance-run-final`.
6. Mark M19 complete only if the immutable aggregate result is `passed`.
