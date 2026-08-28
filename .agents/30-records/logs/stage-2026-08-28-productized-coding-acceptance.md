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
- closed failure taxonomy: model ability, context omission, tool error,
  verification error, permission block and infrastructure
- standalone 10,000-file benchmark covering cold index, single-file update,
  warm query, context build, heap delta and cleanup

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

- focused repo-map and acceptance tests: 15/15 passed
- canonical unit suite: 1692/1692 passed, zero skipped and zero unexpected
- integration: deterministic coding fixtures and work platform passed 2/2;
  two online-provider checks explicitly skipped because credentials are absent
- deterministic end-to-end: 2/2 passed
- built-in offline Eval: 5/5 passed
- Darwin isolation probe: scoped filesystem, controlled network, explicit
  environment, timeout and process-tree cleanup; backend available
- source reader, parenthesis and `git diff --check` checks passed with no
  compiled artifact

## Blocking Evidence

No immutable M9 live result set exists on this machine, and no configured
provider credentials are available for a compatible replay.  The fixed manifest
also has no tagged large-repository coding task.  Therefore the required M9 and
M17 30-by-5 comparison and the 15 percent large-repository token reduction gate
are blocked.  They are not reported as failed model trials and are not replaced
with synthetic data.

Immutable final acceptance record
`eval-20260828T074339110734000-d73d5c` preserves the passing performance
gates, the final test metadata and both blocked evidence gates. Its overall
status is `blocked`.

## Unblock Procedure

1. Add a fixed, versioned, at least 10,000-file coding fixture with a
   `large-repo` task tag and deterministic judge.
2. Freeze provider, model, capability snapshot, profile and task revisions.
3. Run `M-x chat-coding-eval-run-live` with five repetitions for the M9
   configuration and again for M17.
4. Run `M-x chat-coding-acceptance-run-final` with the two result directories.
5. Mark M17 complete only if the immutable aggregate result is `passed`.
