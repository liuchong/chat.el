# Stage Log 2026-08-09 Render Parity and Dead Code (Phase 9)

- Type: logs
- Attention: records
- Status: final
- Scope: project
- Tags: stage, ui, rendering, cleanup

## Summary

Follow-up round after phase 8: code mode render parity, request
panel event collapsing, and dead code removal. Suite: 494 tests,
494 passing.

## What Landed

- `chat-code--render-response-state` gained the streaming fast path:
  when the slot content only grew and the tool event count is
  unchanged, only the tail after the last closed code fence is
  re-rendered (`chat-code--fence-safe-prefix-length`), instead of
  re-parsing the whole response per chunk.
- Code blocks in code mode now use the theme-aware
  `chat-code-block-face` instead of a hardcoded light background
  that broke dark themes.
- The request panel collapses older request events beyond
  `chat-request-panel-max-events` (default 30) with a hidden-count
  line.
- Dead code removed: the leftover stream sentinel helpers in
  chat-ui and chat-code, the broken `chat-ui--get-message-at-point`
  (looked up a text property nothing ever set), and chat-stream's
  unused legacy buffer-insertion globals and functions.

## Test Changes

- New: fence prefix boundaries, code mode delta render growth and
  shrink fallback, panel event collapsing.
- Removed two tests that covered the deleted helpers.

## Verification

- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
  reports 494 results as expected, 0 unexpected.

## Not Done

- Collapsible tool event blocks inside transcripts remain an open
  idea; the panel cap covers the noise problem for now.
