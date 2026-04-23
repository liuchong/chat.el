# Log Item

- Type: logs
- Attention: records
- Status: completed
- Scope: approval-shortcuts
- Tags: approval, shortcuts, minibuffer, request-panel

## Summary

Added fast approval shortcuts on top of the existing synchronous approval flow so pending approvals shown in the request panel now have a direct execution path.

### Technical Decisions

- Kept `completing-read` as the underlying approval mechanism instead of rewriting approvals into a new async interaction model
- Added pending approval state in `chat-approval.el` so command shortcuts can target the active approval request
- Installed approval shortcut bindings in the minibuffer prompt and surfaced the same hints through request panel events

### Completed Work

- Added approval commands for once, session, tool, command, and deny decisions
- Added pending approval state and decision storage
- Added action hints to approval event context
- Updated the request panel to render approval shortcut guidance
- Added tests for approval command state updates and action-hint propagation

### Verification

- Ran `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- Result: `193` tests run, `191` passed, `2` skipped, `0` failed
- Skipped tests remained the existing provider-bound Kimi integration checks:
  - `chat-llm-kimi-simple-request`
  - `chat-llm-kimi-streaming-request`

### Remaining

- Shortcut-driven approval still depends on minibuffer execution and is not yet a panel-local action system
- The request panel teaches the shortcut flow, but the main chat buffers still do not foreground those shortcuts aggressively
