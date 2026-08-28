# Durable Work Plans And Native Progress UI

Status: planned
Date: 2026-08-28
Roadmap: coding reliability M14

## Goal

Give substantial coding work an explicit, durable TODO plan that constrains the
Agent loop, preserves progress across compaction and restart, and communicates
current state without destabilizing the chat input surface.

## Boundaries

A `chat-task` answers "what schedulable unit of work exists and is it running?"
A `chat-work-plan` answers "which ordered steps remain inside that task and
what evidence completes each step?" A work note stores task knowledge. None of
these contracts duplicates the others.

The UI owns fold state and rendering only. Runtime state remains authoritative.

## Plan Contract

`chat-work-plan` schema version 1 contains:

- stable ID and optimistic revision;
- session and foreground task ID;
- objective and mode: `auto`, `required` or `off`;
- status: `active`, `completed`, `blocked` or `cancelled`;
- ordered plan items;
- creation, update and completion timestamps;
- bounded metadata and optional skip record.

`chat-work-plan-item` schema version 1 contains:

- stable item ID, title and order;
- status: `pending`, `in-progress`, `completed`, `blocked` or `skipped`;
- dependency item IDs;
- bounded acceptance description;
- evidence IDs;
- start/completion timestamps and bounded blocker reason;
- bounded metadata.

Invariants:

- one plan has at most one `in-progress` item;
- dependencies must exist and form a DAG;
- an item cannot start before every non-skipped dependency completes;
- completed requires at least one resolvable evidence ID;
- blocked requires a reason;
- terminal plan status cannot return to active without an explicit new
  revision/resume operation;
- every mutation supplies the observed plan revision; stale writes fail.

## When A Plan Is Required

`required` always requires a plan and `off` is an explicit user choice. `auto`
allows an audited skip only for:

- `answer-only`: no tool or external action;
- `read-only`: bounded inspection with no mutation, child task or execution;
- `single-bounded-action`: one deterministic mutation with one owned target and
  no repair or delegated work.

The runtime checks again before the first mutating tool, child task, repair
round or second substantive action. If no active plan exists, the action is
blocked with `plan-required`; the Agent can create a plan and retry. A prompt
request alone is not considered enforcement.

Any multi-file mutation, delegated child, merge, repair loop or project-level
verification is non-simple and cannot use a skip reason. Skip is a durable
event with reason and observed action facts.

## Operations And Evidence

Public operations create/read/list/update/resume/cancel plans and transition
items. A single update may replace the future pending tail while preserving
completed item identity and evidence. Changing the objective increments the
revision and records the source event.

Evidence IDs refer to existing runtime facts, including:

- file observation or write-set records;
- checkpoint and workspace IDs;
- execution and verification result IDs;
- review finding/resolution IDs;
- child task IDs;
- bounded user confirmation events.

The plan store validates that an evidence ID is syntactically valid and known
to the current session/task before completing an item. It stores IDs, not
copied output.

## Agent Projection

Each turn receives only the active slice:

- objective and plan revision;
- current item and its acceptance text;
- incomplete direct dependencies;
- unresolved blockers;
- remaining item titles and aggregate progress;
- evidence added since the previous turn.

Completed history is available through the plan read operation. It is not
repeated in every prompt. The projection is a typed context fragment and is
rebuilt after compaction.

## Recovery

Plans are atomically persisted and load without starting work. A plan saved
with an `in-progress` item after process restart loads as `blocked` with reason
`interrupted`; it requires explicit resume. Completed evidence remains linked.
Unsupported future schemas fail before mutation. A task without a historical
plan remains readable and only encounters the plan gate when it next attempts
a governed action.

## Native Chat UI

The chat buffer shows a compact, unframed one-line progress projection directly
above the input area while an active plan exists. The line contains current
step/total, changed-file count and diff additions/deletions when those runtime
facts exist. Missing facts are omitted rather than guessed.

`TAB` or mouse-1 toggles a native folded detail region listing status, title and
blocker reason. Familiar fixed-width glyphs and faces distinguish completed,
active, pending and blocked items. Long CJK titles and paths wrap without
changing the width of controls. A text terminal receives plain glyph fallbacks.

Rendering rules:

- update the existing plan region instead of appending a new one;
- preserve input point and mark;
- preserve every non-following window's `window-start`;
- a window already following the bottom scrolls only by the minimum required;
- no recenter, overlay leak, timer per event or full transcript redraw;
- UI fold state is buffer-local and never changes durable plan state.

The request panel and task detail view may show the same public projection but
cannot become separate sources of plan truth.

## Events And Trace

Events cover plan creation, update, skip, item start/completion/blocking,
resume, cancellation and plan completion. Payloads contain IDs, revisions,
status, counts and evidence IDs, not objective or output bodies.

Trace reports plan-required refusals, item transitions, blockers, audited
skips, stale revisions, time per item and plan drift such as tools used outside
the current item's declared acceptance.

## Acceptance

- every non-simple fixture has an active plan before its first governed action;
- every allowed skip matches one enumerated reason and observed action shape;
- illegal transitions, cycles, dual active items, stale revisions and
  evidence-free completion are refused without durable mutation;
- cancel, restart, compaction, repair and child tasks preserve plan identity,
  current item and evidence;
- UI and public API always show the same revision and status;
- 1,000 consecutive updates move neither input point nor user scroll position
  and leave no timers or overlays behind;
- the active plan projection uses at most 5% of median input tokens on the
  large-task fixture;
- canonical tests pass with zero unexpected results.
