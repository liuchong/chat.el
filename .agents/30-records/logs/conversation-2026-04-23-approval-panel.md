# Log Item

- Type: logs
- Attention: records
- Status: completed
- Scope: approval-panel
- Tags: approval, whitelist, request-panel, shell, ui

## Summary

Integrated approval and shell whitelist decisions into the request panel so execution flow is observable end to end instead of splitting across hidden minibuffer prompts.

### Technical Decisions

- Extended approval observer events rather than creating a second approval-only state path
- Kept approval input on the existing Emacs decision path while making the request panel the primary read surface
- Emitted explicit `whitelist-update` events when `allow-command` adds a shell command pattern to the allowlist
- Added command context to whitelisted shell execution approval events so auto-approved command runs still explain themselves in the panel

### Completed Work

- Added command and option metadata to `approval-pending` events
- Added command context to `approval` events
- Added `whitelist-update` events for command-level allowlist mutations
- Updated request panel rendering to show approval commands, choices, and whitelist changes
- Added tests for approval observers, panel rendering, and tool-caller whitelisted command context

### Verification

- Ran `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- Result: `191` tests run, `189` passed, `2` skipped, `0` failed
- Skipped tests remained the existing provider-bound Kimi integration checks:
  - `chat-llm-kimi-simple-request`
  - `chat-llm-kimi-streaming-request`

### Remaining

- Approval decisions are visible in the panel, but selection still happens through minibuffer input
- Panel entries are more structured, but the panel is still plain text rather than a richer execution timeline
