# Log Item

- Type: logs
- Attention: records
- Status: completed
- Scope: approval-discoverability
- Tags: approval, discoverability, minibuffer, emacs-native

## Summary

Pushed approval shortcut discoverability into native Emacs prompts and immediate status feedback so users can learn the flow without opening the request panel first.

### Technical Decisions

- Kept approval teaching inside Emacs-native prompt and minibuffer `message` paths
- Reused one shared approval hint formatter so prompt text and pending-approval status feedback stay aligned
- Avoided transcript insertion and avoided any widget-style UI that would fight the existing Emacs workflow

### Completed Work

- Added shortcut hints to approval prompts
- Added shared pending-approval message formatting
- Added first-occurrence approval hint announcements in chat mode and code mode
- Added tests for prompt hints and approval hint generation

### Verification

- Ran `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- Result: `196` tests run, `194` passed, `2` skipped, `0` failed
- Skipped tests remained the existing provider-bound Kimi integration checks:
  - `chat-llm-kimi-simple-request`
  - `chat-llm-kimi-streaming-request`

### Remaining

- Approval discoverability is stronger, but there is still no status-line or header-line specific affordance for pending approvals
- The flow remains intentionally Emacs-native rather than panel-local action driven
