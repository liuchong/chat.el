# Focus

- Type: progress
- Attention: active
- Status: active
- Scope: current-stage
- Tags: focus, current, stage

## Doing Now

Executing the approved unified agent kernel plan
(`~/.kimi/plans/moon-girl-black-widow-raven.md`).

- Phase 1 done: `lisp/core/chat-agent.el` kernel with event stream,
  callback stop conditions, steering, cancellation, truncation refusal,
  and finish-reason plumbing.
- Phase 2 done: plain chat migrated onto the kernel; diagnostics
  traces bounded by `chat-request-diagnostics-max-events`.
- Phase 3 done: code mode migrated onto the kernel; kernel learned
  `:followup-request-options`. 454 tests passing.
- Phase 4 next: async shell tool with timeout and output spill.

## Not Doing Now

- No rollback to the legacy `docs/ai-contexts/` workflow
- No parallel tool execution (interactive approval requires serial)
- No session tree branching (parent-id/branch-ids stay extension points)
- No feature-flag dual loop during migration; tests guard parity
- No security hardening passes unless they block a functional stage

## Immediate Next Step

Phase 4: async shell execution. Port the kimi-cli/pi design into
`chat-tool-shell.el`: `make-process` based execution, default 60s
timeout (foreground capped at 300s), output truncation with spill to
a temp file, and reuse of the same executor for the `!` prefix path.
