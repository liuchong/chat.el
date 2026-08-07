# Stage Log 2026-08-08 Agent Kernel Phase 4 (async shell)

- Type: logs
- Attention: records
- Status: final
- Scope: project
- Tags: stage, shell, async, timeout, truncation

## Summary

Phase 4 of the unified agent kernel plan: shell execution is now
subprocess based with timeout and output limits, following the
kimi-cli and pi designs. Suite: 457 tests, 457 passing.

## What Landed

- `chat-tool-shell--execute-argv` now runs commands through
  `make-process` and pumps `accept-process-output`, so Emacs stays
  responsive while commands run. The blocking `process-file` path is
  gone.
- Timeout: `chat-tool-shell-timeout` (default 60s), capped by
  `chat-tool-shell-max-timeout` (300s). An optional `timeout` tool
  parameter lets the model extend the default within the cap.
  Timed-out commands are killed and reported in-band.
- Output limits: `chat-tool-shell-output-max-lines` (2000) and
  `chat-tool-shell-output-max-chars` (50000). Truncated output spills
  into a temp file whose path is reported (pi's spill-to-file).
- stderr is captured separately and appended as a `[stderr]` section;
  non-zero exits report `[exit status N]` in-band instead of throwing
  an opaque error, so the model can react to real output.
- The `!` prefix path benefits automatically through
  `chat-tool-shell-execute`.

## Lessons

- A `:stderr` buffer collects a sentinel status line (`Process
  chat-shell stderr finished`), with a possible `<N>` process-name
  suffix and a trailing newline. Recorded in
  docs/troubleshooting-pitfalls.md.

## Test Changes

- New: non-zero exit status reporting, timeout kill, truncation with
  spill file verification.
- Updated: the registered tool spec now includes the optional
  `timeout` parameter.

## Verification

- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
  reports 457 results as expected, 0 unexpected.

## Not Done

- Background shell mode (kimi-cli's run_in_background with required
  description) is deferred.
- Phases 5-8: edit robustness and diff display, session JSONL,
  AGENTS.md ancestor stacking, UI rendering.
