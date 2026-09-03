# Prompt Pinned to the Bottom During Live Redraw

- Type: stage-record
- Attention: active
- Status: implementation-verified
- Scope: live-turn rendering window management
- Date: 2026-09-03

## Incident

During streaming the input prompt jumped to the window top and every output
line above it became invisible. Two window positions were mishandled by the
pre-redraw snapshot in `chat-ui--capture-live-window-state`:

1. A window start inside the redrawn tail was captured as an advance-on-insert
   marker. Deletion collapsed it to the tail's start, and re-insertion then
   dragged it past the whole reply, so the restore put the prompt at the
   window top.
2. A window riding the bottom with its cursor in the input area (the state
   after every send) had its old start restored verbatim. While that start was
   still valid the view froze and the prompt slid off the bottom as the tail
   grew; once the start entered the tail it hit defect 1.

## Corrected Contract

A window showing the buffer end rides the bottom like a terminal: the redraw
re-anchors its start to the last screenful, the prompt stays at the bottom
edge, the newest output above it, and the cursor's text position in the input
is never moved. A reading position inside the tail (not at the bottom) keeps
its line distance from the buffer end -- the tail buffer never ends with a
newline, so `count-lines` includes the partial last line and the walk back is
one line shorter than the count. A reading position in the stable history is
restored by marker exactly as before.

The follow rule itself is unchanged: a scrolled-up reader is never yanked, and
a following window still lands its point on the response edge.

## Verification

- `tests/manual/repro-prompt-jump.el` reproduces the jump on the pre-fix
  revision (window start dragged to the last line) and shows the pinned
  bottom after the fix, for both tail-inside and stable-history starts.
- New ert coverage:
  `chat-ui-live-output-pins-the-prompt-to-the-bottom`,
  `chat-ui-live-output-keeps-distance-for-a-tail-reading-position`,
  and the revised `chat-ui-follow-live-output-never-yanks-input-point`
  (the cursor keeps its own position; the view may re-anchor).
- Full suite: 2046 passed, 0 unexpected.
