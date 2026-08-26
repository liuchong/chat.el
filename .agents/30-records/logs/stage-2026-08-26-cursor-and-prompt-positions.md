# Stage: Where The Cursor Is, And When The Screen Says So

- Type: log
- Attention: record
- Status: done
- Scope: project
- Date: 2026-08-26
- Tags: prompt, cursor, input-area, responsiveness, redisplay

## What Was Asked

Four reports, summarised by their author as "the cursor's position
relative to the prompt, fixed and cleaned up, and the send made more
responsive".

1. `/cmd ls` from AI mode leaves the cursor in front of the prompt, and
   what is typed next comes out wearing the prompt's colour.
2. `/send ...` from cmd mode also moves the cursor forward off the input
   instead of leaving it after the prompt.
3. Sending feels like it waits for the request to succeed before showing
   anything. It should show the question at once and report a failure if
   one comes.
4. Arrow keys still reach in front of the prompt, and from there it can be
   deleted -- after which it is ordinary text that `C-a` and `C-e` walk
   over and anything can remove.

## One Cause Behind The First Two

Both are the prompt being redrawn with point sitting at its start.
`save-excursion` restores point through a marker, and a marker at the
start of a region that is deleted and rewritten comes back before the new
text rather than after it. Claiming the line widens the prompt (`> ` to
`cmd> `) and releasing it narrows it, so every claim change walked the
cursor out in front.

The colouring in the first report is the same edit seen from the other
side: with the cursor in front of the prompt, `self-insert-command`
inserts with inheritance next to text that had a face and no stickiness
declared. The `rear-nonsticky` added when the prompt was protected
already covers it; a test now says so, since nothing did.

The fix is to record how far into the input point sat and restore it by
arithmetic against the new marker. Point above the input is left where it
is -- a reader scrolled up in the transcript is not to be pulled down to
the input because a prompt changed width.

## The Fourth Was Already Closed

Deleting the prompt with the arrow keys and a forward delete is refused
by the protection added in the previous stage; the report describes the
build before it. Coverage was missing for that direction, though -- the
existing test pressed backspace from after the prompt -- so the case is
now tested from in front of it, with `delete-char` and `kill-line`.

## Responsiveness: The Frame That Was Never Drawn

The suspicion in the third report was that the send waits on the request.
It does not, and the measurement says the wait is not where it looks:
`chat-ui--prepare-messages-with-tools` is about 13ms on a thirty-message
session, context preparation 0.1ms, the redraw 0.5ms, the session save
0.7ms. Seventeen milliseconds is not a stutter anyone can feel.

What was missing was a paint. A command's buffer changes do not reach the
screen until the command returns, and this command went on to prepare and
start the request, so the question was in the buffer and invisible for the
whole of it. The live waiting line was worse: drawn by a refresh timer one
second out, so the first second had no indicator at all. Question and
waiting state therefore arrived together, once the request was already on
the wire -- which is exactly what "it responds only after the request
succeeds" looks like from the outside.

So: draw the live region once at the point the request is created, where
the phase already reads `Preparing stream request`, and `redisplay` before
the preparation. Not a deferral. Moving 17ms off the command loop would
buy nothing measurable and would cost the synchronous contract the rest of
the send path and its tests are written against -- the reverse of an
optimisation.

## Verification

1021 tests pass, seven new. Typing after the prompt does not take its
colour; the prompt cannot be deleted from in front of it; claiming and
releasing the line both leave the cursor after the prompt, with what is
typed next landing in the input; a redraw mid-word keeps point mid-word; a
reader above the input is not moved; and the question and a waiting line
naming the transport are both on screen before any request work is done,
asserted by capturing the buffer from inside the preparation step.
