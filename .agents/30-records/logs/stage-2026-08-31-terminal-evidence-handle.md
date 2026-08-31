# Terminal Evidence Handle

- Date: 2026-08-31
- Invalid campaign: `m19-baseline-deepseek-v4-flash-e4367f8-r1`
- Harness revision: `e4367f8f89411f3b1388dd45793debdb388ec1f5`
- Tags: evaluation, timeout, cancellation, evidence, model-identity

## Incident

The first full frozen-baseline attempt was stopped after two durable results.
The failed locate trial retained three exact DeepSeek request identities. The
120-second failing-test trial terminated as `cancelled` with no executor
metadata, even though real requests had occurred.

The outer task timeout called Agent cancellation. Agent cancellation emitted a
synchronous `agent-end: cancelled`, which completed Eval before the outer
timeout could write its authoritative `timed-out` status. The executor contract
returned only a cancel function, so Eval had no independent way to freeze
in-flight request and usage evidence before cancellation.

## Decision

An asynchronous Eval executor now returns a typed handle with two operations:

- `snapshot` freezes bounded answer and executor metadata without stopping work;
- `cancel` stops the underlying executor after the snapshot is captured.

Eval records its intended terminal status before invoking either operation.
Late or synchronous executor completion cannot overwrite the snapshot or the
outer `timed-out`/`cancelled` decision. Synchronous executors return nil after
calling their completion callback; every other return value is rejected.

The final aggregator independently validates every live trial. `requestCount`
must be positive and equal the number of request records; every record must
contain a request ID and match the executor provider/model. Missing or drifting
terminal evidence is infrastructure-invalid and cannot satisfy a sample gate,
regardless of result status.

## Verification

- timeout/cancel race regression: passed;
- Eval, request runtime and acceptance tests: 92/92 passed;
- integration tests: 3/3 passed, with two credential-gated Kimi cases skipped;
- end-to-end tests: 3/3 passed;
- canonical suite: 1923/1923 passed with no skips when the acceptance PATH
  includes both Homebrew and `~/.cargo/bin`;
- the shared temporary-state fixture now isolates the durable task directory,
  registry and scheduler guard. This removed three order-dependent background
  process failures without changing product behavior;
- frozen-baseline live timeout smoke
  `m19-baseline-terminal-evidence-smoke-11d8a43-r1` completed as `timed-out`
  after the configured 10-second outer budget. It preserved three non-empty
  request IDs, all exactly `deepseek/deepseek-v4-flash`, plus three usage
  samples and bounded aggregate usage;
- the invalid two-result campaign is retained as incident evidence and must
  never be resumed after the implementation revision changes.

The canonical suite must run with the provisioned toolchain visible. Omitting
Homebrew made executable preflight and verification commands appear blocked;
omitting `~/.cargo/bin` skipped two Rust isolation checks. Those runs diagnose
an invalid acceptance environment and are not product results.

## Harness Ownership Incident

The next formal baseline
`m19-baseline-deepseek-v4-flash-3cc672e-r1` was stopped after two results. The
120-second result initially captured request identity, but the frozen M9
checkout then serialized its 4,166-byte executor metadata with the historical
whole-object bound. The durable metadata became only a truncation marker, so
task, campaign and request identities disappeared together. Continuing would
have produced infrastructure-invalid samples.

The systemic defect was contract ownership, not the 4 KiB scalar limit. The
runner loaded current coding campaign orchestration over the historical Agent,
but left the generic Eval serializer owned by the frozen checkout. It now
reloads both current harness modules after the historical implementation and
verifies representative persistence functions resolve inside the harness root.
The implementation still owns Agent, tool and transport behavior; it cannot
control result bounding, persistence, resume identity or final validation.

Campaign usage now projects only the five normalized numeric counters. Raw
provider usage remains transport diagnostics and is not copied into every task
result. Generic Eval keeps its independent scalar, collection and depth bounds,
so oversized optional leaves cannot erase their enclosing identity structure.

## Harness Ownership Verification

- revision `296d2b6bc1539ddadf61703f65c28a5de13fb01a`;
- focused Eval/campaign/acceptance tests: 96/96 passed;
- canonical suite: 1925/1925 passed;
- integration and E2E commands passed; E2E was 3/3;
- frozen and current 30-task, five-repetition preflights passed against the same
  manifest digest and exact `deepseek/deepseek-v4-flash` identity;
- the real frozen-baseline campaign
  `m19-baseline-terminal-evidence-smoke-296d2b6-r1` reached the exact 120-second
  task timeout and completed with status `timed-out`;
- its 3,934-byte result retained task, repetition, campaign, implementation,
  provider and model identity, ten non-empty request IDs, ten requests and nine
  usage samples; all request identities were exact DeepSeek v4 Flash;
- no `raw` usage key was persisted and metadata was not replaced by a truncation
  marker;
- the temporary one-task manifest and every campaign process were removed.

## Remaining Work

Both stopped formal campaign directories remain immutable incident evidence and
must never be resumed. Start fresh full baseline and current campaigns from
clean revision `296d2b6`. Neither timeout smoke enters the 30-by-5 sample matrix.
