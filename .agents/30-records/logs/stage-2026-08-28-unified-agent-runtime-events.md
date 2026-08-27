# Stage: Unified Agent Runtime Events

- Type: logs
- Attention: records
- Status: complete
- Scope: agent-runtime
- Tags: events, audit, approval, tasks, subagents, compaction

Date: 2026-08-28
Spec: 014
Decision: 0019

## Result

M0 and M1 establish the first shared Agent Runtime contract. `chat-event`
version 1 now carries lifecycle identity, correlation, source, bounded payload
and policy outcome. It uses the existing session wire rather than creating a
second event store.

Blockers and observers are intentionally different APIs. Blockers run in
registration order only at declared boundaries and may allow, modify or refuse.
Security failures and timeouts close the boundary; notification failures stay
visible but do not stop work. Observers run after persistence and cannot alter
the action.

Session, turn, prompt, tool, permission, background task, child-agent and
compaction paths now emit lifecycle records. Guard reviews retain their
established record kind while using the same event pipeline. Guard review and
permission records for one tool call share a task identifier, so rule/model
judgment and the effective outcome can be joined without positional guesses.

## Safety Details

- Live subjects are never persisted.
- Producer context cannot replace runtime-owned event identity or decision
  fields.
- Invalid blocker modifications are rolled back and handled by the event's
  failure policy.
- A modified tool call has its resource accesses recomputed before scheduling,
  so policy changes cannot invalidate concurrency decisions.
- Permission requests and effective resolutions are separate ordered records.
- Background task documents now carry a schema version and session identity.
- Session format version 1 remains readable, and the existing loader and
  regression fixture migrate the earlier single-JSON session format to JSONL
  without altering the source before a successful read.

## Verification

The canonical suite passes 1387/1387 with zero unexpected results. Added
coverage includes observer isolation and order, blocker modification and
refusal, timeout, failure policy, audit metadata ownership, successful, failed
and cancelled turn closure, tool execution refusal, resource conflict recomputation,
permission record pairing, compaction refusal, task lifecycle and child-agent
lifecycle.

No background service was started during implementation. Test processes ran in
the foreground under the repository memory cap and timeout wrapper.

## Next Stage

M2 introduces model capability facts and one normalized transport event
stream. The first migration carries text, reasoning, tool deltas, usage and
errors through one provider path; offline fixtures then hold that behavior
stable while the remaining adapters move behind the same contract.
