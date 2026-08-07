# Stage Log 2026-08-07 Functional Fix Pack

- Type: logs
- Attention: records
- Status: final
- Scope: project
- Tags: stage, fixes, tool-calling, session, shell

## Summary

Stage A of the functional remediation plan from the deep review
(`conversation-2026-08-07-deep-project-review.md`).
All fixes verified with the canonical batch suite: 443 tests, 443 passing
(429 baseline plus 14 added or updated).

## Fixes

1. Tool call parser no longer hangs on an unclosed ```json fence
   (`chat-tool-caller--extract-fenced-json` advances past the opener).
2. Malformed tool call attempts now feed a parse error follow-up back to
   the model instead of silently ending the loop. Both async tool loops
   (chat-ui and chat-code) continue on `:parse-error` until the step
   limit.
3. `!cd` special case works again: the guard regex had an empty trailing
   alternative, and `match-end` was read after `string-match-p`, which
   preserves match data instead of publishing it.
4. `chat-tool-shell--split-command` replaces `split-string-and-unquote`
   so single-quoted arguments (awk, sed scripts) survive tokenization.
5. Tool follow-up messages now carry real result content up to
   `chat-tool-caller-result-max-chars` (default 8000) in both chat and
   code mode. Code mode previously fed the model only a 240 character
   summary, which blinded it after `files_read`.
6. Message ids are unique per process via
   `chat-session-new-message-id` (timestamp plus monotonic counter)
   instead of `(random 10000)`.
7. Session saves are atomic (temp file plus rename), loads tolerate
   corrupt files, and `chat-session-list` skips nil loads.

## Notes

- One existing test (`chat-code-tool-followup-summarizes-structured-results`)
  was updated because it encoded the old summary-only contract that fix 5
  intentionally changed.
- 34 stale `.elc` files shadowing sources were deleted from the working
  tree. They were untracked and gitignored.
- `tests/unit/test-chat-files.el` still carries an older uncommitted
  verified stage from before this session.

## Verification

- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
  reports 443 results as expected, 0 unexpected.

## Not Done

- Async shell execution, preview/diff layer repairs, AGENTS.md nested
  discovery, provider-aware context budgets, and UI rendering work remain
  open as later stages.
