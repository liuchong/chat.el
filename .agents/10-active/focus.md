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
  and finish-reason plumbing. 453 tests passing.
- Phase 2 next: migrate plain chat (chat-ui) onto the kernel, delete
  the old loops, cap diagnostics traces per request.

## Not Doing Now

- No rollback to the legacy `docs/ai-contexts/` workflow
- No parallel tool execution (interactive approval requires serial)
- No session tree branching (parent-id/branch-ids stay extension points)
- No feature-flag dual loop during migration; tests guard parity
- No security hardening passes unless they block a functional stage

## Immediate Next Step

Phase 2: rewrite chat-ui send paths (`chat-ui--get-response-sync`,
`chat-ui--get-response-streaming`, `chat-ui--resolve-tool-loop-async`)
as a view over `chat-agent-start`, rewrite the loop contract tests as
kernel plus thin view tests, and bound per-request diagnostics traces.
