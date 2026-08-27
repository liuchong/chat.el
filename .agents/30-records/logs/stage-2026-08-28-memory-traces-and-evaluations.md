# Stage: Memory, Traces And Evaluations

- Type: logs
- Attention: records
- Status: complete
- Scope: agent-runtime
- Tags: memory, provenance, traces, evaluations, observability

Date: 2026-08-28
Spec: 014, 019
Decision: 0025

## Result

M7 adds three versioned runtime contracts. Structured memory records source,
scope, confidence, retention, sensitivity and status while preserving the
directly editable `memory.md` note. Trace reconstructs sessions, Turns and task
parentage from numbered wire archives plus the current stream. Evaluations run
versioned deterministic scenarios and persist immutable bounded results.

Native Emacs views make each contract inspectable. Memory supports add, edit,
merge, archive, delete and automatic-capture control. Trace lists Turn timing,
token and work counters and exposes detail, export and comparison. Evaluation
commands run one or all offline scenarios, isolate live scenarios behind an
explicit command and expose result detail, export and comparison.

## Correctness Details

- Legacy and structured memory share one prompt-size ceiling.
- Sensitive, expired, archived and out-of-scope items never enter prompts.
- Automatic candidates are disabled by default and expire unless reviewed.
- Cross-scope merges require an explicit target and retain source identities.
- Trace is derived on demand and never creates a second event database.
- Torn records, gaps, duplicate sequences, unknown kinds and missing parents
  remain readable and diagnosable.
- Trace exports omit prompts, message bodies and complete tool payloads.
- Evaluation values are redacted and bounded before persistence or export.
- The five built-in offline scenarios cover editing, Guard, recovery,
  compaction and normalized provider events without network access.
- Live scenarios are excluded from the canonical and default UI runs.

## Verification

The canonical suite passes 1511/1511 with zero unexpected results. Focused
tests cover structured-memory persistence and scope, complete wire reading,
Trace timing and parentage, immutable evaluation evidence, bounded exports and
the three native views. All touched Lisp files pass `check-parens`; byte
compilation reports only established repository warnings from dependencies.

Static scans found no forbidden cross-project references or copied transcript
content in durable Trace and evaluation projections. All commands ran in the
foreground under the repository memory cap; no server or background process
was started.

## Next Stage

M8 adds `termini.el` through a versioned bridge for dispatch, progress,
cancellation, artifacts and completion while preserving local runtime
independence.
