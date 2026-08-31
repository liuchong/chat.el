# Memory, Trace And Evaluation Runtime

Status: complete
Date: 2026-08-28
Roadmap: M7
Decision: 0025

## Goal

Give long-running agents inspectable continuity and reproducible regression evidence
without hidden prompt growth, sensitive-data propagation or a duplicate telemetry
database.

## Memory Contract

Memory is durable knowledge intended to remain useful beyond the current task.
It is distinct from the session/task-scoped working notes in Spec 021. Working
notes may hold current decisions, blockers and next steps, expire with the work
scope and are never promoted to long-term memory or instruction authority
without an explicit operation.

`chat-memory-item` schema version 1 contains:

- item ID and bounded text content;
- source kind and source ID;
- global, project or session scope plus the matching scope ID;
- confidence in the inclusive range zero through one;
- creation, update and optional expiry timestamps;
- permanent, expiring or session retention;
- normal or sensitive classification;
- active, archived or rejected status;
- bounded metadata.

Creation validates every enum, required identifier, confidence and size limit. A
secret-like classification is refused rather than persisted. Update preserves identity
and creation time. Merge creates one attributable item, archives the inputs and records
their IDs. Delete removes the durable item. Expired items remain reviewable but are not
retrieved.

Retrieval accepts an optional session and filters in this order: active status,
expiration, sensitivity, then scope. Project scope matches the canonical working
directory recorded by the session; session scope matches only that session ID. Results
are ordered deterministically by scope specificity, confidence, update time and ID.
Prompt injection is capped across both legacy and structured memory.

The existing `memory.md` remains directly editable and readable. Its non-empty content
appears as one user-curated global block. Structured items live in an atomic,
schema-versioned JSON document under the memory directory. Automatic memory is off by
default and exposes an explicit toggle; candidate capture cannot make sensitive data
prompt-visible.

Public operations:

- list and retrieve effective items;
- add and update an item;
- archive, delete and merge items;
- review item provenance and injection eligibility;
- edit the compatible note and toggle automatic capture.

## Complete Wire Reading

`chat-session-wire-read` keeps its established behavior and reads only the current
stream. `chat-session-wire-read-all` reads numbered archives followed by the current
stream, skips malformed lines, filters optional kinds once and returns records sorted
by sequence. Duplicate sequence numbers keep their first observed record and produce a
diagnostic count in Trace. Missing sequence numbers are reported, not invented.

Archive discovery escapes the session ID before matching filenames and sorts numeric
indices numerically. A malformed or missing archive cannot prevent later readable
records from appearing.

## Trace Contract

`chat-trace` schema version 1 contains:

- session and optional Turn identity;
- first and last sequence and timestamps;
- derived status and completion reason;
- first-output and total duration measurements;
- input, output, total, cache-read and cache-write token totals;
- counts for model rounds, text and reasoning events, tools, approvals, tasks,
  subagents, compactions, checkpoints and executions;
- task nodes with parent identity and bounded status facts;
- unknown-kind, duplicate-sequence and missing-sequence diagnostics.

A session trace contains ordered Turn traces. Events without a Turn remain in the
session summary. Parent references may arrive before or after children; reconstruction
therefore builds identities first and links second. Missing parents remain explicit
roots rather than being attached by guesswork.

First output is the first text, reasoning, tool-call or terminal model event after a
Turn start. Total duration ends at the terminal Turn event, falling back to the last
record when the Turn was interrupted. Token values are summed only when numeric.
Unknown and old-schema records are tolerated and counted.

Trace export is a bounded JSON projection of this structure. Comparison reports status,
duration, token and count deltas for matching session or Turn records. It never exports
message bodies, prompt content, credentials, complete tool arguments or complete tool
results.

## Evaluation Contract

`chat-eval-scenario` schema version 1 contains an ID, revision, category, description,
fixture ID, tags and executable. The executable returns named checks with pass/fail,
expected and bounded actual facts. An exception becomes a failed check rather than
aborting the remaining suite.

`chat-eval-result` schema version 1 contains a unique result ID, scenario identity and
revision, fixture identity and digest, start and finish timestamps, duration, aggregate
status, named checks and bounded metadata. Results are immutable atomic JSON files.

Bounding is structural. Scalar text is redacted and byte-bounded, collections have an
item bound, and nesting has a depth bound. Exceeding one leaf limit replaces that leaf
with an explicit truncation record; it must not replace the enclosing metadata object.
Identity and decision fields such as task, campaign, provider, concrete model and actual
request IDs therefore remain recoverable even when a sibling diagnostic is oversized.
Persistence that erases those fields is invalid evidence and cannot complete a campaign.

The built-in offline suite covers:

- editing ownership and bounded file facts;
- Guard deterministic floor and recorded decision facts;
- checkpoint drift refusal and explicit recovery semantics;
- compaction preservation of protected instructions;
- normalized provider text, reasoning, tool and usage events.

Scenarios assert public contract outcomes and normalized event shapes, never provider
wording. They use no network, credentials, clock-dependent prose or live process.
Optional live scenarios use a separate command and are excluded from canonical tests.

Evaluation comparison matches scenario ID and revision, then reports changed checks,
status and duration. Different revisions are rejected as incomparable.

## Native UI

The memory view lists scope, confidence, sensitivity, status, update time, source and a
bounded content preview. Detail commands expose full local content and provenance.
Mutating commands require an explicit selected item and refresh after success.

The Trace view lists Turns with status, duration, first-output latency, tokens, tools,
approvals and tasks. A detail view shows correlation IDs, task parentage and diagnostics.

The evaluation view runs the offline suite or one scenario, lists immutable results and
opens named checks. Commands expose bounded JSON export and result comparison.

## Acceptance

- old `memory.md` content remains readable, editable and capped;
- structured memory survives restart and rejects malformed or unsupported schemas;
- project and session items never appear in another scope;
- expired, archived and sensitive items never enter a prompt;
- memory merge preserves source IDs and delete removes the item;
- disabling automatic memory stops candidate persistence without changing sessions;
- all wire archives and the current stream reconstruct in sequence order;
- torn lines, unknown kinds, gaps and duplicate sequences remain diagnosable;
- nested and parallel task IDs retain their recorded parentage;
- latency, token, cache, tool, approval, task, compaction, checkpoint and execution
  measurements are derived without copied transcript content;
- every built-in evaluation is deterministic offline and identifies its fixture;
- comparisons expose changed contract checks and reject accidental revision mixing;
- native views operate entirely through the public Memory, Trace and Evaluation APIs;
- the canonical suite passes with zero unexpected results.

## Verification

The canonical suite passes 1511/1511 with zero unexpected results. Focused
coverage verifies durable and scoped memory, secret refusal, archive reading,
Trace reconstruction and diagnostics, immutable bounded evaluation results,
the five offline runtime scenarios, native view projections and explicit live
scenario isolation. All touched Lisp files pass `check-parens`.
