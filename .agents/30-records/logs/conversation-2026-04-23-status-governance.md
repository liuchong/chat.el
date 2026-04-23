# Log Item

- Type: logs
- Attention: records
- Status: completed
- Scope: status-governance
- Tags: status, governance, approval, emacs-native

## Summary

Defined and enforced a shared rule for native status surfaces so only blocking approval states remain persistent while transient tool activity stays out of header-line, mode line, and top status lines.

### Technical Decisions

- Added `lisp/ui/chat-status.el` as the shared eligibility rule for persistent status surfaces
- Kept the first persistent rule intentionally narrow: only `approval-pending` qualifies
- Left transient states such as `thinking` and ordinary `tool-call` events in the request panel or echo-area hints

### Completed Work

- Added shared persistent-status helpers
- Updated chat mode and code mode to use the shared rule
- Added negative tests proving non-blocking states do not leak into persistent status surfaces
- Updated knowledge records so future changes extend the rule deliberately

### Verification

- Ran `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- Result: `200` tests run, `198` passed, `2` skipped, `0` failed
- Skipped tests remained the existing provider-bound Kimi integration checks:
  - `chat-llm-kimi-simple-request`
  - `chat-llm-kimi-streaming-request`

### Remaining

- Future stages may need to evaluate whether any blocking state besides approvals deserves persistent surfacing
- Chat mode and code mode still render their status surfaces separately even though the rule is now shared
