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
- standalone Goal and Plan reliability measurement that emits the complete
  final-aggregator metadata contract and rejects uncommitted evidence

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

Focused campaign `m19-smoke-go-multi-file-20260829T083500` ran one committed
`go-multi-file` trial. Its wire trace confirms that post-tool events now carry
the owning `agent_task_id`, and the Agent successfully created and advanced its
durable plan with a native evidence array. One earlier transition used the old
JSON-string shape and was rejected before reaching the compatibility parser.
Tool parameters now keep the provider-visible array schema while accepting an
explicitly declared legacy string type at runtime; this metadata survives tool
persistence. The canonical suite passes 1793/1793.

The smoke could not reach a functional verdict because the provider exhausted
its seven-day usage allowance during the trial. Both write approvals received
the same 403 from the guard model and failed closed; Eval recorded the terminal
trial as infrastructure `error` with no workspace leak. This result is useful
availability evidence, but it is neither a coding failure nor a passing smoke.
No further final-campaign requests should be sent until the fixed provider and
model are available again.

## Runtime Reliability Evidence

`tests/performance/run-runtime-reliability.el` closes the former gap between
the typed `runtimeReliability` gates and their producer. It runs 17 gate-linked
checks covering 15 unique Goal and Plan ERT scenarios in isolated state,
including the 20-turn/two-compaction/reload/restart continuity case, then
measures 20 growing prompt projections.
Before writing JSON it feeds the values through
`chat-coding-acceptance-reliability-gates`, so a producer/consumer contract
drift fails the command rather than creating plausible-looking evidence.

The development run passed every directed scenario and all nine acceptance
gates. Rates were `1.0`, safety counts were `0`, and the Goal projection median
was `0.0032043746239855107` of measured input tokens. It remains diagnostic
evidence because it records a dirty implementation tree.

A clean replacement record was generated at implementation revision
`875433ce249d0c7f3fc72126ec74b076b73392ef` on 2026-08-29. It records
`implementationTreeClean: true`, passes all nine acceptance gates, preserves
the same `1.0` rates, zero safety counts and
`0.0032043746239855107` Goal projection median, and is stored at
`~/.chat/evaluations/coding-acceptance/runtime-reliability-875433c.json`.
Its SHA-256 is
`4118104d2e0f8ee0810a8ccd6f4b7ca39fcdd5a9fcc824c0f1b4fdff44e52cc8`.
Final aggregation must consume this complete JSON object rather than a manual
transcription.

The final aggregator now enforces that requirement with a separate
`runtime-reliability-record` gate. It recomputes the nine value gates and
requires the clean current implementation revision, the exact 17 directed test
records across 15 unique scenarios, and all 20 ordered Goal projection samples.
Missing provenance, a dirty tree, a revision mismatch, rewritten gate records
or incomplete samples remain blocked even if the nine summary values pass.
Focused acceptance tests pass 30/30 and the canonical suite passes 1810/1810.

Canonical command:

```text
CHAT_RELIABILITY_OUTPUT=/absolute/path/runtime-reliability.json /Users/liu/projects/.agent-tools/capped.sh 2048 emacs -Q -batch -l tests/performance/run-runtime-reliability.el
```

## Non-Live Quality Evidence

`tests/performance/run-quality-reliability.el` produces the independent quality
record required for deterministic M19 gates outside the live model comparison.
It executes 48 exact directed scenarios, recomputes definition accuracy,
reference precision/recall and Top-5 from raw corpus rows for Python,
TypeScript, Emacs Lisp, Go and Rust, measures 20 plan/work-note prompt samples,
and recomputes Review precision/recall from expected and reported finding IDs.

The clean record at revision
`875433ce249d0c7f3fc72126ec74b076b73392ef` passes all 20 quality gates. Every
semantic metric is `1.0` overall and per language, Review recall is `1.0`,
Review precision is `0.875`, and the prompt median is
`0.003149300780049963`. It is stored at
`~/.chat/evaluations/coding-acceptance/quality-reliability-875433c.json`; its
SHA-256 is
`adba31d88705a349a4f7057f291c249b3c3cb7b7aad8a97ab1e6c5587303e795`.

The `quality-reliability-record` gate rejects a dirty or mismatched revision,
missing language, skipped or incomplete directed scenario, insufficient prompt
samples, changed finding sets, or rewritten summary gates. The canonical
producer command is:

```text
CHAT_QUALITY_RELIABILITY_OUTPUT=/absolute/path/quality-reliability.json /Users/liu/projects/.agent-tools/capped.sh 4096 emacs -Q -batch -l tests/performance/run-quality-reliability.el
```

## Canonical Suite Evidence

`tests/run-tests.el` now writes an optional strict record through
`CHAT_CANONICAL_OUTPUT`. It structurally reads every top-level `ert-deftest`
declaration under `tests/unit`, records every exact test identity and result,
and exits nonzero for expected failures, unexpected results, skips or aborts.
The clean record for revision `875433ce249d0c7f3fc72126ec74b076b73392ef`
contains 1810/1810 passed, zero failed, zero skipped and zero unexpected. It is
stored at `~/.chat/evaluations/coding-acceptance/canonical-875433c.json`; its
SHA-256 is
`b7f57145c6510ecb4c3409edf00e2b49264b9575b87cab53c7d0ce67d728d91b`.

The final aggregator's `canonical-suite-record` gate requires the same clean
current revision and an exact ordered match to the repository's current test
declarations. A passing summary cannot hide a removed, renamed or failed test.

Canonical command:

```text
CHAT_CANONICAL_OUTPUT=/absolute/path/canonical.json /Users/liu/projects/.agent-tools/capped.sh 4096 emacs -Q -batch -l tests/run-tests.el
```

## Frozen Campaign Runner

`tests/live/run-coding-campaign.el` is the committed entry point for both
replacement roles. It requires explicit campaign, provider/model,
implementation revision and harness revision identity; actual runs reject a
dirty or mismatched checkout. `CHAT_CAMPAIGN_PREFLIGHT=1` validates the complete
descriptor without network access or durable trial output. An actual run loads
credentials only from an explicit trusted local setup file and proves the exact
provider/model is ready with one bounded request before creating the campaign.

The baseline may load the historical implementation from a separate checkout
while overlaying the frozen current campaign contract, and should use an
isolated runtime home. If a run reaches a provider availability failure such as
transport exhaustion, rate limiting, quota exhaustion, service unavailability
or capacity pressure, the failed attempt is archived, the run lock is released
and the campaign pauses without consuming that repetition/task identity. Agent
request retries remain narrower than this campaign-level stop boundary.

Clean no-network preflight passed for both replacement roles under harness
revision `875433ce249d0c7f3fc72126ec74b076b73392ef`. The current role uses that
same implementation revision; the baseline role uses
`e4e6cbcec89a8a0d5f67d15a861ace9d9b4965d3`. Both descriptors contain 30
tasks, five repetitions and 150 expected results with manifest digest
`4ef1e36f8ae44456e2bc4dcf8f661adfdbe916e3a57024dca384107773e3fd38`.
Their configuration digests are respectively
`cf5bc65e878ed32645347f341c43a803f669778962e511576007f727a17749a4`
and `eb36461d214c64719d15e36478a4f1eefa96a143011b347ebe9ece763b01c3e7`.
The subsequent live readiness request returned the provider's explicit HTTP
403 seven-day quota error, and the runner confirmed that no campaign directory
was created.

Provider availability returned on 2026-08-29. Replacement current campaign
`m19-current-deepseek-v4-flash-20260829T055205Z` recorded 124 immutable trials
at revision `8c54ac0`: 104 passed, 15 cancelled, four failed and one errored.
A truncated stream was correctly quarantined as an attempt and paused the run
without consuming its trial identity. The pause then exposed a runner defect:
the batch entry called the new-campaign API for an existing directory instead
of the strict resume API. The runner now selects start or resume explicitly,
and regression tests prove the paths are mutually exclusive.

All 15 cancelled results ended at the exact 120-second task timeout. Rust wire
traces showed repeated `no installed toolchains`: isolated runtime HOME was set
before the Darwin backend could resolve the original developer `.rustup` root.
The runner now preserves the resolved `RUSTUP_HOME` before replacing HOME;
sandbox policy still grants only command-scoped read access for Rust commands.
Campaign `m19-smoke-rust-refactor-20260829T075142Z` at revision `1230618`
completed 1/1 in 27.735 seconds with the targeted cargo test passing, five of
five checks passing, 12 tool calls and results, zero tool errors and trusted
usage. Canonical development tests pass 1818/1818. The 124-result campaign is
incident evidence only because its implementation revision predates these
fixes; final acceptance still requires fresh 30-by-5 comparison campaigns.

## Unblock Procedure

1. Keep the completed M9 baseline and `aa4698a` current campaign immutable as
   historical evidence; do not append or rewrite either campaign.
2. Commit the Rust runtime, native plan/evidence schemas, scoped Evidence ID
   feedback and generated-output contract, then freeze the resulting
   implementation and manifest revisions.
3. Preflight the committed runner for both frozen checkouts, then run fresh
   30-by-5 baseline and current campaigns against that exact manifest; never
   resume a campaign across an implementation or manifest revision.
4. Establish trusted token coverage for at least 95 percent of both replacement
   comparison sets. The historical baseline cannot satisfy this gate.
5. From a clean frozen revision, run all three standalone evidence commands and
   pass the complete runtime, quality and canonical JSON objects to
   `chat-coding-acceptance-run-final`; do not transcribe summary values by hand.
6. Mark M19 complete only if the immutable aggregate result is `passed`.

## 2026-08-31 Dual-Provider Continuation Diagnostic

Revision `60196d3` was exercised against the exact replacement models before
the next implementation change. Campaign
`m21-common-kimi-code-k3-256k-60196d3-r1` used `kimi-code` / `k3-256k`;
campaign `m21-common-deepseek-v4-flash-60196d3-r1` used `deepseek` /
`deepseek-v4-flash`. Both wire records retained assistant reasoning across
tool turns without a provider continuation 400.

Kimi passed `coding/elisp-locate` in 24.479 seconds. Its
`coding/elisp-failing-test` run reached the 120-second task deadline after the
first compile approval review abstained at 20.005 seconds and a retry allowed
the command 10.804 seconds later. The late compile then observed the already
cancelled and cleaned workspace. This is Guard latency plus cancellation-order
evidence, not a semantic Kimi denial.

DeepSeek passed `coding/elisp-locate` in 13.478 seconds. It correctly repaired
and tested `coding/elisp-failing-test`, but the evaluator rejected completion
because the active Plan remained open. The model attempted
`programming_plan_transition`; the runtime replied that the tool was
unavailable for the turn. Root cause was a non-atomic capability transition:
Plan creation removed `programming_plan_create` and exposed execution tools,
but did not expose the remaining Plan lifecycle operations. Plan creation now
atomically advertises those operations before execution continues, while the
completion barrier remains strict.

Both campaigns were intentionally stopped after these two diagnostic tasks.
They remain immutable diagnostic evidence and do not replace a complete paired
acceptance campaign. The Plan lifecycle fix must be committed and the same
provider/model cases rerun on the new revision.
