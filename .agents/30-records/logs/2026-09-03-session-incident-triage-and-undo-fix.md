# Session Incident Triage and Undo-Recording Fix

- Type: logs
- Attention: records
- Status: complete
- Scope: ui, transport
- Tags: performance, undo, gc, stream-net, incident-triage

## Summary

A real session reported four problems: a conversation that appeared not to
work and to loop, an unexpected plan gate, a stray "Progress" label, and
a heavy Emacs that would not let the cursor move while a run was in
flight.

Investigation separated the four:

1. The loop was the transport doing its bounded work against an
   unreliable line. `api.xgapi.top` timed out repeatedly at the 30s
   connect ceiling, the endpoint cooled down, the fallback endpoints
   failed their TLS handshake (confirmed from the host with curl), and
   mid-stream breaks were re-sent within the two-attempt resume bound.
   Every retry and cooldown is finite by design; the instability lives
   upstream, not in the client. No code change.
2. The "plan gate" was the session's own durable work plan, created by a
   coding run and left `blocked` (item 6 interrupted by the same network
   incidents). Plan Mode was never entered; the gate that blocked a
   background task was the work-plan check under a code-capable session,
   working as designed. No code change.
3. The "Progress" label is the interim prose label by design
   (decision 0010: interim prose is italic and labelled so it is not
   mistaken for the answer). Rendering defect: none.
4. The heavy editor was real and had one cause: `chat-mode` left
   `buffer-undo-list` recording. Streaming redraws are edits, so the undo
   list grew to tens of thousands of entries in one long reply, and the
   next send walked it into ten garbage collections. The `[TIMING]` lines
   name it: `undo 186` on the half-second sends, `undo 89883` on the
   eight-second ones; a fresh session (undo 231) restored the half
   second immediately. Fixed by turning undo recording off in `chat-mode`
   -- the display holds nothing undoable, and edit rollback uses backup
   files, not Emacs undo.

Also removed a duplicated `defcustom chat-stream-connect-timeout` in
`lisp/core/chat-stream-net.el`: two definitions of one setting, already
drifted in their documentation, one shadowing the other.

## Changes

- `chat.el`: `chat-mode` sets `buffer-undo-list` to `t`, with the
  measurement evidence in the comment.
- `lisp/core/chat-stream-net.el`: the second, shadowed definition of
  `chat-stream-connect-timeout` is deleted.
- `tests/unit/test-chat.el`: `chat-mode-does-not-record-undo` asserts the
  recording stays off across edits.
- `tests/unit/test-chat-stream-net.el`:
  `chat-stream-net-defines-each-setting-once` reads the transport source
  and fails if any `defcustom` is named twice.
- `docs/troubleshooting-pitfalls.md`: new entry "The Undo List Recording
  A Rendering That Is Never Undone" under the measurement cluster.

## Verification

Baseline before the change: `emacs -Q -batch -l tests/run-tests.el
-f ert-run-tests-batch-and-exit` ran 2069 tests, 2067 expected, 2 skipped
(environment), 0 unexpected. After the change the same command ran 2071
tests, 2069 expected, 2 skipped, 0 unexpected. The two new tests pass in
isolation.
