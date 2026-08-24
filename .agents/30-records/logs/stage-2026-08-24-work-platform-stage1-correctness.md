# Stage Log

- Type: logs
- Attention: records
- Status: complete
- Scope: work-platform-stage1
- Tags: agent, transcript, privacy, schema, tests

## Summary

Completed Stage 1 correctness, privacy, and contract work for the work
platform track.

## Changes

- Added `chat-agent-transcript` so UI hosts persist loop-emitted
  assistant and `:tool` messages in order.
- Changed chat UI and code-mode finalizers to render completed state
  without creating bundled assistant tool-result history.
- Preserved provider tool call ids across session save and load.
- Let active chat and code-mode input steer the running agent instead of
  rejecting normal input while a response is active.
- Kept explicit stop predicates ahead of queued steering, while allowing
  queued steering to run before the default no-tool stop.
- Scoped Emacs live-buffer tools to project buffers or the current
  non-file buffer by default, with credential-like buffer names hard
  denied.
- Fixed zero-argument provider tool schemas and forged-tool parameter
  persistence.
- Moved config loading before persisted tools and plugins start.

## Verification

- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- Result: 527 tests, 527 passing.

## Remaining Work

- Per-step context transforms, typed events, cancellation propagation,
  stream contract unification, and resource-aware scheduling remain for
  Stage 2.
