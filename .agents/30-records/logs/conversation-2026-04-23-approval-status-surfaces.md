# Log Item

- Type: logs
- Attention: records
- Status: completed
- Scope: approval-status
- Tags: approval, header-line, mode-line, status, emacs-native

## Summary

Promoted pending approvals onto persistent native Emacs status surfaces so approval state stays visible after echo-area hints disappear.

### Technical Decisions

- Used existing `header-line` and mode line infrastructure in code mode instead of introducing new overlay or widget layers
- Added a lightweight top status line helper in chat UI rather than changing transcript content
- Reused current tool-event state instead of inventing a separate approval state model just for status rendering

### Completed Work

- Added pending approval extraction helpers in chat mode and code mode
- Added code mode header-line and mode line approval indicators
- Added chat UI status line approval indicator
- Added tests for status rendering in both chat mode and code mode

### Verification

- Ran `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- Result: `198` tests run, `196` passed, `2` skipped, `0` failed
- Skipped tests remained the existing provider-bound Kimi integration checks:
  - `chat-llm-kimi-simple-request`
  - `chat-llm-kimi-streaming-request`

### Remaining

- The approval status is now persistent, but further emphasis could still become noisy if overused
- Chat mode and code mode still maintain separate rendering implementations for similar status concepts
