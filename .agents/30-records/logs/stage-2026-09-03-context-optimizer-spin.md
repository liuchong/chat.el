# Code Context Optimizer Spin on Dense Short Files

- Type: stage-record
- Attention: active
- Status: implementation-verified
- Scope: chat-context-code budget optimizer
- Date: 2026-09-03

## Incident

A Code session froze Emacs (99% CPU, main loop captive) the moment a new
message was sent.  Live sampling showed a regexp-heavy `while` loop inside an
interactive command; offline reproduction with the session file pinned it to
`chat-context-code--optimize`.

The context was 8225 tokens against an 8000 budget.  The focus file was a
review log written that day, a handful of very long lines (embedded JSON).
`chat-context-code--truncate-file-context` halved by *lines* with a floor of
ten lines, so a dense file of fewer than twenty lines came out of
"truncation" exactly the same size; `find-largest-file` picked it again
forever.  `with-timeout` could not break the loop because a pure Lisp loop
never reaches timer checks -- only SIGUSR2's `maybe_quit` path did.

## Fix

Truncation now halves by characters (floor 200).  A file becomes eligible at
over 100 tokens, i.e. over 400 characters, so character-halving provably
shrinks every eligible file and the loop converges logarithmically.  The
existing remove-lowest-priority and give-up fallbacks are unchanged.

## Verification

- Offline repro with the frozen session's file now completes optimize and
  renders in milliseconds.
- New ert regression:
  `chat-context-code-optimize-shrinks-dense-short-files`.
- Full suite: 2057 passed, 0 unexpected.
