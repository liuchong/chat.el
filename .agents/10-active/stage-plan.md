# Stage Plan

- Type: progress
- Attention: active
- Status: active
- Scope: agent-runtime
- Tags: stage, plan, memory, tracing, evaluations

## Goal

Deliver M7: provenance-aware memory, reconstructable Trace records and a
deterministic Agent evaluation harness.

## Completed

- M0-M5 runtime contracts, lifecycle events, model capabilities, extensions,
  unified tasks and typed multimodal content
- M6 owned-file checkpoints and independent code/conversation rollback
- optional owned worktrees with restart reconciliation and explicit cleanup
- one versioned local execution backend with durable attempt history
- canonical verification at 1484/1484

## Next Steps

1. Define versioned memory, Trace and evaluation contracts before extending the
   current memory implementation.
2. Add provenance, scope, confidence, timestamps, retention and sensitivity to
   every durable memory item.
3. Preserve existing explicit memory commands through a compatibility reader,
   then add review, edit, merge, delete and automatic-memory controls.
4. Reconstruct one Trace tree from lifecycle, model, task, execution,
   permission, checkpoint and artifact records using stable correlation IDs.
5. Record bounded latency, token, cache, tool, approval, compaction and task
   measurements without copying prompts, secrets or unbounded output.
6. Build deterministic offline scenarios for editing, Guard, recovery,
   compaction and provider protocol behavior.
7. Add native memory and Trace inspection commands, then run focused and
   canonical verification before stage closeout.

## Risks

- Automatic memory can preserve stale, incorrect or sensitive conclusions if
  provenance and retention are weak.
- Trace joins can duplicate or mis-parent events when correlation is absent or
  adapters emit terminal state more than once.
- Evaluations can become brittle if they assert provider prose instead of
  contract-level outcomes.
- Metrics must stay bounded and must not become a second transcript containing
  prompts, credentials or full tool output.

## Next Entry

Record the M7 memory/Trace/evaluation decision and acceptance spec before
implementation begins.
