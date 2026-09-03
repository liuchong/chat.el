# Durable Work Plans And Native Progress UI

Status: implemented — DEPRECATED (this release)
Date: 2026-08-28
Roadmap: coding reliability M14

> **DEPRECATED (2026-09-04): the work-plan *mode* mechanism — the `auto` /
> `required` enforcement gate and the `programming_plan_mode` tool — has
> been **removed** this release and is not coming back.**
>
> Why: `required` enforcement plus the single in-progress-item rule,
> combined with the runtime-recovery that resets the in-progress item on
> every new run, could lock a model out of *every* tool call — the plan
> could not advance and no governed action could run, leaving the run to
> spin in plan-management with 0 steps. This release deletes the gate:
> `chat-work-plan-check-call` and its helpers are gone, no tool call is
> gated on a plan, and `programming_plan_mode` is no longer advertised or
> registered. The bounded-skip side channel (`programming_plan_skip` /
> `chat-work-plan-skip`), which existed only to bypass the gate, is
> removed with it. The durable plan *record* and its lifecycle tools
> (create/read/transition/resume/cancel) and the Plan Mode UI remain for
> progress visibility; only the enforcement machinery was removed.

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

## Plan Enforcement (Removed)

The `auto` / `required` / `off` enforcement gate and the `single-bounded-action`
skip side channel are **removed** this release (see the DEPRECATED block above).
No tool call is blocked on a plan: the plan record, staged provider menu,
lifecycle tools and read-only Plan Mode remain for progress visibility only.

The provider-facing `programming_plan_create` operation is present in the
initial programming menu and atomically starts the earliest dependency-ready
item for ordinary coding; the initial menu otherwise contains only inspection
operations. Successful ordinary creation exposes every file mutation operation,
including structured multi-file patching, and compile operations for the next
model turn, while a restored ordinary plan exposes them when the run starts.
Once a plan exists, the provider menu removes `programming_plan_create` and
exposes the existing plan lifecycle instead. A second plan cannot be proposed
until the current plan reaches a terminal state.
Read-only Plan Mode never exposes those execution operations. This staged
surface keeps plan-before-mutation structural rather than merely prompt-guided.

## Operations And Evidence

The programming profile exposes `programming_plan_create`,
`programming_plan_read`, `programming_plan_list`, `programming_plan_update`,
`programming_plan_transition`, `programming_plan_resume`,
`programming_plan_cancel` and `programming_plan_mode_enter`. A single update
may replace the future pending tail while preserving completed item identity
and evidence. Changing the objective increments the revision and records the
source event.

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
repeated in every prompt. The projection is a typed context fragment, has an
independent 2,000-character hard limit and is rebuilt after compaction. Each
run records the last projected plan revision, so later turns include only
evidence added after that revision.

The provider prompt keeps lifecycle guidance for as long as plan transition
tools are exposed. Before creation it explains the one atomic create step.
After creation it states that the existing plan is authoritative, forbids a
second create call, and tells the Agent to complete the active item with exact
evidence before advancing with the returned revision. Removing the create tool
must not also remove the instructions needed to close the active plan.
Creation therefore changes the current turn menu atomically: it removes
`programming_plan_create`, exposes every authorized Plan lifecycle operation,
and, outside read-only Plan Mode, exposes the execution tools. A lifecycle tool
present in the provider request must remain executable against that same menu;
schema advertisement without runtime availability is a contract violation.
The textual prompt and native provider schemas derive from the same
session-filtered turn menu. Neither may consult the global registry after a
Session has narrowed its advertised tools.

Both contracts are rebuilt for every request from the current execution Session.
A tool mutation on one turn can change the next turn's menu, Plan revision and
active item, so a system-tools message prepared before the run is only a template,
not an immutable provider contract. The canonical Session is the sole authority
for durable Plan, Goal, note and workflow state. Stateful tools receive that
Session explicitly. The execution Session is a transient policy copy that owns
only the current provider tool menu and approval policy; after every successful
tool call its metadata is replaced from the canonical Session. Synchronization in
the opposite direction is forbidden because a stale execution copy can erase the
state the tool just committed. Plan context and the completion barrier always read
the canonical Session directly.

An applicable `active` or `blocked` plan is a completion barrier. Tool-free prose
while a plan is active is progress, not a final answer. The runtime may issue a
bounded request-only finalization instruction only when another turn can still
advertise the Plan lifecycle tools. A blocked plan stops with
`work-plan-blocked`; an active plan that cannot be closed within the bounded
attempts stops with `active-plan-unclosed`. A terminal plan permits ordinary Agent
completion.

## Recovery

Plans are atomically persisted and load without starting work. A plan saved
with an `in-progress` item after process restart loads as `blocked` with reason
`interrupted`; it requires explicit resume. Completed evidence remains linked.
Unsupported future schemas fail before mutation. A task without a historical
plan remains readable and only encounters the plan gate when it next attempts
a governed action.

## Native Chat UI

The chat buffer shows a compact, unframed one-line progress projection directly
above the input area while a plan exists. The line contains current step/total
and title. Runtime facts that do not exist are omitted rather than guessed.

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

The session wire records bounded `plan-created`, `plan-updated`,
`plan-item-started`, `plan-item-completed`, `plan-item-blocked`,
`plan-item-skipped`, `plan-resumed`, `plan-cancelled`, `plan-completed` and
`plan-revision-conflict` events. (The gate-era `plan-skipped`,
`plan-skip-consumed` and `plan-required` events were removed with plan-mode
enforcement.) The Agent loop additionally records
`work-plan-finalization` when it retries closure or stops at the completion
barrier. Payloads contain IDs, revisions, status and bounded facts, never objective
or output bodies. Derived Trace can report these transitions and refusals without
maintaining a second plan store.

## Acceptance

- every non-simple fixture has an active plan before its first governed action;
- every allowed skip matches one enumerated reason and observed action shape;
- illegal transitions, cycles, dual active items, stale revisions and
  evidence-free completion are refused without durable mutation;
- cancel, restart, compaction, repair and child tasks preserve plan identity,
  current item and evidence;
- UI and public API always show the same revision and status;
- textual tool guidance and native provider schemas expose the same current menu
  after every Plan transition;
- a stateful tool writes the canonical Session, the execution Session observes the
  committed metadata before the next request, and stale execution metadata can
  never overwrite canonical state;
- an active or blocked plan can never produce a completed Agent run, while a
  terminal plan can complete normally;
- 1,000 consecutive updates move neither input point nor user scroll position
  and leave no timers or overlays behind;
- the active plan projection uses at most 5% of median input tokens on the
  large-task fixture;
- canonical tests pass with zero unexpected results.

## Verification Record

- plan contract and recovery: 16 focused tests;
- native UI stability: 3 focused tests, including 1,000 updates;
- Agent gate and request-only projection: 2 focused tests;
- completion barrier, dynamic tool contract and canonical-state synchronization:
  focused unit and full live-tool-path regressions;
- programming profile surface: capability-pack regression coverage;
- canonical suite: 1,894/1,894 passing after the canonical-state authority fix.
