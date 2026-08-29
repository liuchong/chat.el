# Input Work Shelf

- Type: record
- Attention: reference
- Status: complete
- Scope: chat-ui
- Tags: input, disclosure, todo, goal, plan, changed-files

## Result

The former separate TODO, Goal and Plan Mode projections are replaced by one
default-closed input work shelf. A stable `▸`/`▴` control is the first prompt
segment. Opening it projects non-empty TODO, changed-files, Goal and Plan
providers in canonical order; each section has independent `▸`/`▾` disclosure.

Only the glyphs own mouse-1. They do not move point or bind keyboard input.
Rendering preserves input-relative point, draft text and every visible window's
start. Provider events update only the affected section unless availability
changes, in which case the bounded shelf is rebuilt to preserve canonical order.

## Changed-File Boundary

Changed files are a strict session-owned ledger of successful checkpoint effects.
Direct write completion records add, modify, delete or rename facts; failure and
capture alone record nothing. Rollback removes the checkpoint evidence and
rederives the current projection. The renderer performs no Git or filesystem
scan, so unrelated dirty files cannot be attributed to the conversation.

Repeated writes converge on one entry. Rename provenance follows the file, but
operation state remains net: a conversation-created file that is later renamed
is still an addition. This distinction was found during implementation review
and is now covered directly.

## Lessons

- Keep runtime attribution as typed evidence; never infer ownership from display
  state or repository dirt.
- Preserve input position relative to the input marker. Inserting rows above the
  prompt necessarily changes absolute buffer coordinates.
- Use text-owned section regions for incremental replacement and a right-sticky
  temporary end marker when replacing the last section.
- Put mouse keymaps only on disclosure glyphs. A line-wide keyboard map quietly
  turns status text into a second input mode.
- Bound provider summaries and details before they reach the renderer.

## Verification

- Focused changed-file, checkpoint, provider and UI tests cover attribution,
  rename/delete/rollback, ordering, bounds, no directory scan, mouse-only
  controls, incremental refresh and 1,000 redraws without point or scroll drift.
- Focused acceptance: 198/198 passed.
- Canonical project suite: 1,857/1,857 passed.
