# Transport-Resilient Live Campaigns

- Type: record
- Attention: reference
- Status: complete
- Scope: agent-runtime, coding-eval
- Tags: transport, retry, campaign, recovery, acceptance

## Incident

The `m19-current-20260828T220053` campaign reached its 150-result terminal
matrix, but it is not valid capability evidence. The result distribution was
2 passed, 11 failed, 133 errored and 4 cancelled. Session-wire records classify
131 errors as transport exit code 6 and two as exit code 35: DNS and TLS
connectivity failures. Only 17 trials remained after infrastructure-invalid
results were excluded, so the strict 30-by-5 valid-sample gate rejects it.

The run also exposed a separate in-memory defect. Completion passed a
destructively reversed result list to its callback, leaving the suite state's
list shortened even though all 150 immutable files were correct.

The replacement `m19-current-20260829T002859` campaign exposed a second
infrastructure defect and was stopped after 19 results. Batch requests carried
a request id without creating a UI diagnostics trace. Stream diagnostics tried
to read a chunk counter from that absent trace and raised inside the process
filter. The current payload survived, but every later SSE line delivered in
the same process output block was skipped. Agent answers consequently arrived
truncated or scrambled and produced false task failures and timeouts.

The first clean streaming smoke then found a Darwin isolation defect. The
AppKit Emacs executable resolves its Core Foundation home independently from
`HOME`. Inside the deny-default build sandbox it reached the developer's named
color list as a noneditable object and aborted before running tests. Binding
`CFFIXED_USER_HOME` to the backend-owned temporary home keeps that process
state inside the sandbox and lets batch Emacs start normally.

The next smoke completed the edit but exposed a verification-loop defect. The
executor ran the repository's whole test suite instead of the task's targeted
command, then could not inspect its own background-task log through the file
tool because that log correctly sits outside the workspace boundary. An
unrelated intentional test failure consequently turned a correct change into a
timeout.

## Contract

- A model request that fails before any payload on a known transient transport
  error retries asynchronously after 2, 5, 10 and 20 seconds. The 37-second
  retry budget stays below the 120-second fixed-task timeout, so exhaustion can
  reach the campaign pause path instead of racing the task timer.
- Retry waiting remains cancellable. Cancelling a chat or evaluation cancels
  the pending timer and produces one terminal run event.
- Every retry wire event records its attempt, delay and bounded error message.
- Live Eval results preserve the final `failureReason` in executor metadata.
- If all transport retries are exhausted, a live campaign moves that result
  into its immutable `attempts/` archive, releases the run lock and pauses.
  The failed attempt does not claim the repetition/task identity, so validated
  resume schedules it again after connectivity recovers.
- Completion callbacks receive an ordered copy. They cannot mutate or shorten
  the suite state's own result list.
- Request diagnostics are optional telemetry, not part of the stream data
  path. An unregistered request id cannot prevent payload or content callbacks
  from consuming every complete SSE line in a transport block.
- Darwin execution binds both the shell home and Core Foundation home to the
  managed temporary root. AppKit-backed command-line tools cannot consult the
  developer's per-user application state during an isolated build.
- Command judges are projected into the executor prompt as exact shell-quoted
  commands. The executor and judge therefore verify the same target rather
  than choosing differently scoped suites.
- The programming capability exposes bounded background-task output, scoped
  to the current session. An agent can inspect its own compiler or test result
  without widening workspace file permissions or reading another session's
  log.

## Verification

- canonical suite: 1777/1777 passed, zero skipped and zero unexpected
- integration: deterministic coding fixtures and work platform passed 2/2;
  two online-provider checks skipped because credentials were absent
- deterministic end-to-end: 2/2 passed
- built-in offline Eval: 5/5 passed
- live post-fix smoke `postfix-smoke-20260829T022300` passed the
  `elisp-failing-test` scenario in 74.5 seconds. The session wire records the
  exact targeted command at step 12, a session-scoped
  `programming_task_output` read at step 13 and a completed final answer at
  step 14; the independent command judge then passed 1/1
- regression coverage includes delayed retry, cancellation during retry,
  synchronous callback ordering, transient-attempt quarantine, resumable
  identity preservation, immutable suite result ordering and multi-payload
  streaming without a diagnostics trace
- a real Darwin deny-default build test starts the installed Emacs binary,
  captures its output and verifies a clean exit under the managed home

## Operational Lesson

A complete file count proves storage completeness, not sample validity.
Infrastructure failures must remain visible, but they must not consume trial
identities or allow one outage to cascade through the remaining matrix.
Likewise, observability must fail open with respect to data collection: a
missing or broken diagnostics side channel must never discard model output.
Background task logs are runtime capabilities, not workspace files. Expose
them through a session-scoped read operation, and make the evaluation command
part of the task contract instead of expecting the executor to rediscover it.
