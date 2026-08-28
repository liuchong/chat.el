# Productized Coding Acceptance

- Type: progress
- Attention: records
- Status: blocked
- Scope: M17
- Tags: runtime-status, diagnostics, performance, eval, acceptance

## Implemented

- six-phase runtime status projection on the unified chat surface
- point and window-anchor preservation across repeated status updates
- actionable closed diagnostics for stale files, semantic capability,
  verification, isolation, permission, timeout and cancellation
- persistent repo-map stem/import indexes and known-path incremental refresh
- strict immutable M17 acceptance gates in the existing Eval store
- exact 30-by-5 live sample validation, identity comparison, success, scope,
  verification and token gates
- isolated live campaign directories with immutable configuration and terminal
  completion records
- campaign gates that reject mixed roles, manifests, configurations or
  implementation revisions
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

## Blocking Evidence

No immutable M9 or M17 live campaign exists on this machine. The running Emacs
session has configured providers, but no 300-trial comparison has been executed.
A no-network compatibility preflight loaded the current campaign harness over
the historical M9 implementation revision
`e4e6cbcec89a8a0d5f67d15a861ace9d9b4965d3`. With the current corpus limit of
12,000 files injected explicitly, it loaded all 30 tasks and produced a
`baseline` descriptor with 150 expected results. This proves the manifest and
campaign contracts can run against M9; it is not a model trial and supplies no
token evidence. Therefore the required M9 and M17 30-by-5 comparison and the 15
percent large-repository token reduction gate remain blocked by missing live
token evidence. They are not reported as failed model trials and are not
replaced with synthetic data.

Immutable final acceptance record
`eval-20260828T081821940433000-365782` preserves the four passing performance
gates, final test metadata, two missing campaign-record gates, the missing live
comparison and the blocked large-repository token gate. Its overall status is
`blocked`.

## Unblock Procedure

1. Freeze one configured provider, concrete model, capability snapshot, profile
   and task revisions.
2. In the clean M9 checkout, load the current campaign harness and set
   `chat-coding-eval-max-fixture-files` to 12,000 before loading the fixed
   manifest. Run five repetitions in a fresh `baseline` campaign.
3. In the clean M17 checkout, run `M-x chat-coding-eval-run-live` with the same
   provider, concrete model and five repetitions in a fresh `current` campaign.
4. Run `M-x chat-coding-acceptance-run-final` with the two result directories.
5. Mark M17 complete only if the immutable aggregate result is `passed`.
