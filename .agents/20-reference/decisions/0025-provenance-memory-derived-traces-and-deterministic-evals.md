# Decision 0025

- Type: decisions
- Attention: reference
- Status: accepted
- Scope: agent-runtime
- Tags: memory, provenance, traces, evaluations, privacy

## Title

Keep memory attributable, derive traces from the event stream and evaluate contracts

## Context

Long-running agents need continuity and measurement, but hidden prompt accumulation
creates three failures at once: stale conclusions become authority, sensitive text can
cross an unintended boundary and nobody can explain why one run behaved differently
from another. A second telemetry database would create a different problem. The
session wire already records versioned lifecycle facts with stable correlation IDs;
copying those facts into a trace store would introduce drift and competing truth.

Evaluations also need a boundary. Provider prose, latency and network availability are
not deterministic enough for the core suite. A useful regression test must identify
its fixture and contract revision, exercise the same public runtime boundary as a real
run and report bounded facts that can be compared later.

## Decision

`chat-memory-item` schema version 1 is the durable memory contract. Every item carries
an ID, content, source kind and source ID, scope and scope ID, confidence, creation and
update times, optional expiry, retention, sensitivity, status and bounded metadata.
Global, project and session scopes are explicit. Retrieval is deterministic and only
active, unexpired, scope-matching, non-sensitive items enter a prompt. Secret-like
items are rejected at the API boundary. Sensitive items may remain locally visible for
review but are never injected or included in ordinary exports.

The existing user-curated `memory.md` remains a compatible global memory source. It is
read as an explicit legacy block and is not silently rewritten into inferred items.
Automatic memory is disabled by default. Enabling it permits candidates to be staged;
it does not bypass provenance, sensitivity or review rules. Users can review, edit,
merge, archive and delete durable items, and can turn automatic capture off without
changing session history.

`chat-trace` schema version 1 is a derived projection, not a new event store. Trace
reconstruction reads all numbered wire archives plus the current stream, tolerates
torn records and orders surviving records by sequence. It groups lifecycle facts by
session, Turn, task and parent IDs and computes bounded measurements: start, first
output, completion, token and cache totals, tool, approval, task, subagent, compaction,
checkpoint and execution counts. Unknown event kinds remain visible as counts rather
than preventing reconstruction. Trace exports contain identifiers, statuses, counts
and measurements only; they do not copy prompts, message bodies, secrets or complete
tool output.

`chat-eval-scenario` and `chat-eval-result` schema version 1 define deterministic
offline evaluation. A scenario has a stable ID, revision, category, fixture identity
and an executable that returns named contract checks. A result records those
identifiers, an input digest, timing, status, checks and bounded metadata. Results are
written atomically and may be compared by scenario ID and revision. Built-in scenarios
cover editing, Guard, recovery, compaction and provider protocol behavior through
public or fixture-backed runtime contracts. Optional live checks are separate and can
never be required by the canonical suite.

Native Emacs views are projections over these public APIs. Editing a view never edits
wire history or evaluation evidence in place; mutations go through the memory API and
new evaluation runs create new immutable result records.

## Consequences

Memory costs more metadata than a plain note, but every injected conclusion can be
explained and removed. Legacy user notes continue to work unchanged. Prompt assembly
becomes session-aware so project and session scope cannot leak into another run.

Trace reconstruction costs a bounded sequential read when requested. That is accepted
because it preserves one source of truth and keeps ordinary execution free of a second
persistence path. Archives are part of the readable history, while the existing
current-stream reader retains its compatibility behavior.

Offline evaluations measure runtime contracts rather than model style. They detect
behavioral regressions reproducibly, while provider quality and live latency remain an
explicit opt-in concern. No M7 component may turn telemetry into another transcript or
silently promote inferred text into standing instructions.
