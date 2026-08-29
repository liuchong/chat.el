# Passive Input Hints

- Type: record
- Attention: reference
- Status: complete
- Scope: input-workflow
- Tags: hints, completion, keyboard, overlay, stability

## Result

The input area now has a generic bounded hint-provider layer. Slash commands are
the first provider. Candidates are filtered from in-memory data, capped at ten,
and displayed alphabetically by default or by successful per-session usage with
lexical tie-breaking.

The rendered list is a zero-width overlay. It has no keymap, focus, selection,
mouse highlight or buffer characters. It prefers available rows below the input,
falls back above it and truncates to the available side while preserving point
and window start.

## Completion Contract

Hints and completion are deliberately independent. `RET` always dispatches the
current input exactly once. `TAB` inserts only a unique candidate or the longest
common prefix shared by all candidates, and never starts a selection session.
Filesystem candidates are computed only on explicit `TAB`; passive refresh does
not synchronously scan disk, history, network, processes or models.

## Lessons

- Display assistance must not acquire input ownership.
- A visible candidate must never silently change the meaning of `RET`.
- Keep passive providers pure, bounded and in-memory; reserve expensive discovery
  for an explicit user action.
- Test negative interaction contracts: no keymap, no mouse face, no selection
  frontend, no buffer mutation and no point or scroll movement.
- Candidate order needs a deterministic fallback even when usage counts tie.

## Verification

- Focused hint, completion, path, send and overlay tests passed as part of a
  44/44 input-workflow run.
- Canonical suite passed 1,847/1,847 with zero unexpected results.
