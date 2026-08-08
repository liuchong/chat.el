# Stage Log 2026-08-09 Stream Error Surfacing and Multi-Session State

- Type: logs
- Attention: records
- Status: final
- Scope: project
- Tags: stage, streaming, errors, multi-session, ux

## Summary

Driven by a real usage failure: a chat with an expired API key
appeared to hang forever with no output. Root-caused to three
stacked bugs, all fixed and proven end to end against the live API
and a local fake server. Suite: 496 tests, 496 passing.

## Root Cause Chain

1. The kimi-code API key in the local config is expired: direct
   curl returns HTTP 401 (user action required: renew the key).
2. curl exits 0 on HTTP 401, so the error body arrives as a plain
   JSON line, not SSE data. The stream parser ignored it and the
   run "completed" with empty content.
3. The body lacks a trailing newline, so it sat in
   `chat-stream--partial-line` and was never processed.
4. The stream sentinel's completion regex `"finished\|exited"` had a
   single backslash in a string literal, so it never matched — no
   flush, and stream buffers leaked on every completed request.

## Fixes

- Non-SSE JSON error bodies are captured
  (`chat-stream-http-error` process property) and the kernel turns
  them into an error event plus `agent-end` with status `error`
  instead of a silent empty completion.
- The stream sentinel flushes the trailing partial line before
  killing the buffer, and its completion regex is fixed to
  `"finished\\|exited"` (also repairing the buffer leak).
- The kernel sentinel treats `abnormally|failed|killed|deleted` as
  failures before accepting `finished|exited` as success.
- `chat-stream--partial-line` is now a declared defvar-local instead
  of an undeclared variable that voided outside the request path.
- chat-ui surfaces terminal states in the echo area (completed /
  stopped / cancelled / error), replacing the stale "Getting
  response from AI..." message.
- Multi-session groundwork: chat-ui request state
  (`active-agent-run`, request handle, stream process, input
  overlay, messages-end) is now buffer-local, so concurrent chat
  buffers no longer share one "active request".
- Layout preference: `chat-request-panel-auto-show` now defaults to
  nil — one big conversation buffer, panel opens on demand.

## Verification

- Real expired-key request now ends with status=error and the API
  message, in both fake-server and live probes.
- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
  reports 496 results as expected, 0 unexpected.

## Not Done

- The expired kimi-code key itself must be renewed by the user.
