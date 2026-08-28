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

## Unblock Procedure

1. Keep the completed M9 baseline and `aa4698a` current campaign immutable.
2. Remove the five cancellation-path scope leaks and reduce or prevent the 37
   task cancellations without weakening deterministic judges.
3. Run a fresh 30-by-5 current campaign after those implementation changes;
   never resume a campaign across an implementation revision.
4. Establish trusted token coverage for at least 95 percent of both comparison
   sets. A replacement baseline is required if the missing M9 usage cannot be
   recovered from original provider evidence.
5. Save same-revision `runtimeReliability` measurements, including the Goal
   projection median ratio, then run `chat-coding-acceptance-run-final`.
6. Mark M19 complete only if the immutable aggregate result is `passed`.
