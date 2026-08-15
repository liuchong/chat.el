# Stage Log 2026-08-15 Cursor Follow Behavior

- Type: logs
- Attention: records
- Status: final
- Scope: project
- Tags: stage, ui, cursor, scrolling

## Summary

Real usage feedback: the cursor felt wrong during streaming. Two
opposite causes, one per mode, both fixed. Suite: 504 tests, 504
passing.

## Causes and Fixes

- Code mode yanked window point to the response edge on every chunk,
  even when the user was typing in the input area.
  `chat-code--follow-live-output` now skips windows whose point is in
  the input area; Emacs keeps the cursor visible naturally there.
- Plain chat had no follow at all and forced a full redisplay per
  chunk. New `chat-ui--follow-live-output` scrolls only windows that
  are already near the bottom edge and whose point is outside the
  input area, and replaces the per-chunk forced redisplay.

## Verification

- Window-stub tests: scrolled-up windows never move, edge windows
  follow, input-area points are never yanked (both modes).
- One legacy test encoded the old yank behavior and was rewritten to
  the new contract.
- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
  reports 504 results as expected, 0 unexpected.
