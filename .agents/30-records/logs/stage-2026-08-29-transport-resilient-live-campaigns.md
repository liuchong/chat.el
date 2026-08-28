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

## Verification

- canonical suite: 1769/1769 passed, zero skipped and zero unexpected
- integration: deterministic coding fixtures and work platform passed 2/2;
  two online-provider checks skipped because credentials were absent
- deterministic end-to-end: 2/2 passed
- built-in offline Eval: 5/5 passed
- regression coverage includes delayed retry, cancellation during retry,
  synchronous callback ordering, transient-attempt quarantine, resumable
  identity preservation and immutable suite result ordering

## Operational Lesson

A complete file count proves storage completeness, not sample validity.
Infrastructure failures must remain visible, but they must not consume trial
identities or allow one outage to cascade through the remaining matrix.
