# Spec 026: Input Work Shelf

- Status: implemented
- Scope: chat input-adjacent runtime projections
- Depends on: typed work plans, Goal, Plan Mode, runtime-owned change evidence
- Replaces: separate always-visible Goal, Plan Mode and TODO projections above input

## Purpose

The line immediately above the chat input is the stable place for compact facts
about the work attached to the current conversation. Those facts must remain easy
to inspect without making every ordinary message start below a permanent dashboard.

The input work shelf provides one extensible region with two-level disclosure:

1. a shelf toggle at the beginning of the input prompt controls the whole region;
2. each non-empty section inside the open shelf has its own collapsed summary and
   independently expandable details.

“Work shelf” is the canonical name. “Two-level disclosure” names the interaction;
it is not a nested selection widget or a popup toolbar.

## Layout And Interaction

The first prompt segment is a familiar disclosure glyph. `▸` means the shelf is
closed; `▴` means it is open. It stays attached to the input prompt and remains
present even when the shelf has no sections, so the control never moves as Goal,
Plan, TODO or file state appears and disappears.

When the shelf is closed, no shelf rows are rendered. This is the default for every
newly opened chat buffer. Clicking the prompt glyph opens it. Opening the shelf
renders its region immediately above the separator and input prompt. Closing it
removes the region but does not change any underlying work state.

Each available section occupies one collapsed summary line beginning with `▸`.
Clicking its glyph expands that section and changes it to `▾`; clicking again
collapses it. Opening the outer shelf does not automatically expand any section.
Section expansion state is buffer-local presentation state, not transcript or
runtime state.

The shelf and sections own mouse-1 only on their disclosure glyphs. They do not
capture input focus, `RET`, ordinary arrows, `TAB` or text selection. Every redraw
preserves input point, input text, window start and manual transcript scroll.

## Initial Sections

Providers return nil when they have no relevant current data; nil sections are not
rendered. Initial provider order is stable:

1. **TODO**: the current durable work-plan projection. The summary shows completed
   count, total count and current item. Details show the existing bounded item list.
2. **Changed files**: files changed by this conversation's attributable runtime
   operations. The summary shows a unique file count. Details show project-relative
   paths and operation state, one file per line.
3. **Goal**: the selected nonterminal Goal contract. The summary shows status and
   bounded objective. Details show stopping condition, criteria and blockers.
4. **Plan**: active Plan Mode state. The summary shows mode status and revision.
   Details show the existing bounded planning projection.

TODO and Plan are separate concepts: TODO is the executable work-plan state machine;
Plan is the read-only planning and approval mode. Their labels and data sources must
not be merged.

## Changed File Contract

“Changed files” means files attributed to successful mutating operations in the
current session. It is not `git status`, the entire checkout's dirty set, recently
viewed files, focus files or paths merely mentioned by the model.

Each current-schema entry contains stable canonical path, project-relative display
path, operation (`added`, `modified`, `deleted` or `renamed`), first and last turn,
latest revision/evidence identity and update time. Repeated writes update one entry;
renames retain provenance. Failed, refused, rolled-back and outside-session writes
do not appear. A successful rollback updates or removes the corresponding entry so
the shelf describes current conversation effects rather than attempted effects.

The ledger is session-owned, durable and updated from runtime-owned write/checkpoint
events after success. It never infers attribution from a repository-wide scan. The
UI reads a bounded indexed projection and performs no filesystem or Git scan while
rendering.

## Provider Architecture

The shelf is a reusable provider registry. A provider has stable ID, priority,
availability predicate, one-line summary renderer, bounded detail renderer and
event dependencies. Providers return typed projection data; they do not insert
directly into the buffer. The shelf renderer owns ordering, disclosure glyphs,
keymaps, region replacement and scroll preservation.

Updates are event-driven and incremental. TODO, Goal, Plan Mode and changed-file
events invalidate only their section. Future bounded sections may register through
the same contract without modifying the prompt or inventing another region.

Queue is a structured runtime source with two complete projections: an input work
shelf projection and a transcript projection. The shelf is not the sole owner of
Queue state. Both projections expose the same stable message IDs, ordering,
revisions, delivery state and actions, and every mutation updates both from the
single authoritative Queue store. The user may choose either projection without
losing Queue functionality.

The shelf Queue provider follows the same two-level disclosure rules as other
sections. Its collapsed summary shows the bounded pending count; details show a
bounded ordered message projection and Queue actions without moving input focus.
Editing a queued message increments its revision and preserves its identity and
audit history. Queue remains distinct from staged or draft messages: a queued
message is committed for later dispatch, while a staged message is not yet queued.
Recalling a queued message first places its authoritative record in `editing`;
that state is a scheduler barrier, so no cached older revision may dispatch while
the input buffer owns the edit.

Insert-mode input that has been sent but not yet injected is not a shelf provider
and is not Queue. It is an uneditable transient transcript projection immediately
above the shelf. Durable or streaming conversation output renders before it, so
the projection stays at the bottom of the transcript until injection atomically
replaces it with the durable user turn.

## Non-Goals

- a graphical toolbar, child frame, menu, selectable popup or second input area;
- showing absent, completed or irrelevant state merely to fill the shelf;
- deriving session attribution from the whole worktree;
- embedding file contents, diffs, sensitive paths or unbounded histories;
- allowing shelf state to alter Goal, Plan, TODO, permission or execution semantics;
- maintaining a shelf-only Queue copy or merging queued and staged message state;
- implementing compatibility paths for the former separate input projections.

## Acceptance

Tests must prove:

- the prompt glyph has a stable position and the shelf defaults closed;
- opening the shelf shows only non-empty providers in canonical order;
- each section defaults collapsed and toggles independently;
- closing and reopening the outer shelf preserves inner disclosure state for that
  buffer while reopening the session in a new buffer starts closed;
- point, input text, `window-start` and manual scroll survive every toggle/update;
- `RET`, `TAB`, arrows and typing keep their chat-input meanings;
- TODO, Goal and Plan use their existing typed projections without duplicated state;
- changed files include successful current-session writes, deduplicate repeated
  writes, represent rename/delete, and exclude viewed/refused/failed/rolled-back or
  unrelated dirty files;
- zero available sections renders no region, while the prompt control remains;
- provider rendering is bounded and performs no synchronous filesystem/Git scan;
- Queue actions, revisions and ordering remain identical between shelf and
  transcript projections;
- a queued record in `editing` cannot dispatch an older revision;
- an insert-mode sent projection remains below live output, is never editable and
  disappears exactly when the durable user turn appears;
- the former separate projections are removed, and the full canonical suite passes.
