# Stage: The Guard Keeps Receipts

Date: 2026-08-27
Spec: 013 (guard model approval)

## What was missing

The policy design called for two complementary forms: deterministic entries
for known forms and semantic rules for the long tail. The implementation had
the semantic half and the irreversible floor, but no narrow allow/deny entry
layer for tuning repeated mistakes.

The spec also required every verdict in the session event log. In practice a
verdict lived only in a bounded Emacs list until someone explicitly exported
it. Closing Emacs lost the evidence needed to review and improve the guard.

## What changed

`chat-approval-guard-allow-command-entries` and
`chat-approval-guard-deny-command-entries` match trimmed whole commands
literally. Deny wins, variants do not inherit an allow, and the floor still
runs before either. Unlisted calls continue to the semantic model. Narrow
adjudication-instruction markers now produce a local abstention rather than
sending an attempted approval injection to the judge.

Every verdict now appends one `approval-guard-review` event to the wire file
for the session it judged. The record includes the entry/model source,
decision, matched rule, reason, confidence, model, latency, shadow reference,
effective outcome and bounded argument summaries. Normal and shadow paths
meet at one recorder, so neither is missed and neither is duplicated.

`chat-approval-guard-session-reviews` returns those persisted payloads for a
loaded session. The existing memory log and JSONL export remain available for
ad hoc tuning runs.

## Verification

Tests cover exact allow without a model request, deny precedence, non-exact
variants falling through to the model, attempted adjudication instructions
abstaining locally, and a durable session record that omits full long
arguments. Canonical suite: 1350/1350.
