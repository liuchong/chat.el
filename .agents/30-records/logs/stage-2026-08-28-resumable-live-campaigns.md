# Resumable Live Campaigns

- Type: record
- Attention: reference
- Status: complete
- Scope: coding-eval
- Tags: eval, campaign, recovery, acceptance

## Trigger

A 30-task-by-5 live campaign was interrupted after its first 30 durable results.
The old runner had no way to reconstruct missing work, so restarting would have
required discarding valid evidence or creating a different campaign.

## Contract

- `campaign.json` freezes provider, concrete model, model-specific capability
  snapshot, profile, transport, approval mode, manifest digest, implementation
  revision, task count, repetitions and expected result count.
- Every result carries campaign identity and a top-level repetition. Older
  records with repetition and runtime identity inside executor metadata remain
  readable for validation.
- Resume loads every result from disk, verifies file and record identity, rejects
  unknown tasks, revision/configuration drift and duplicate repetition/task
  pairs, then schedules only missing pairs in deterministic order.
- A local exclusive lock prevents concurrent scheduling. A lock owned by a dead
  local process is stale and recoverable; a live or foreign-host lock is not
  overridden.
- Cancellation records the active trial and releases the lock without writing
  completion. A hard interruption leaves completed trials durable and the
  unfinished pair missing for the next resume.
- `completion.json` can be written only when the descriptor on disk is unchanged
  and the reported and durable result ID sets are the same complete unique
  matrix. Completed campaigns cannot resume or accept appended results.

## Verification

Focused tests cover one-of-four recovery, exact three-trial scheduling, terminal
completion, duplicate rejection, revision/approval/manifest drift, live and stale
locks, cancellation without terminalization, top-level repetition persistence
and acceptance rejection of a duplicated trial matrix.

- focused coding Eval and acceptance tests: 35/35 passed
- canonical suite: 1765/1765 passed, zero skipped and zero unexpected
- integration: deterministic coding fixtures passed 2/2; two online-provider
  checks skipped because credentials were absent
- deterministic end-to-end: 2/2 passed
- built-in offline Eval: 5/5 passed through `chat-eval-run-all`

## Operational Lesson

Long evaluations must treat each durable trial as the checkpoint. Process memory
may accelerate scheduling but must never be the only source of remaining work or
the authority for completion.
