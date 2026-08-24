# Focus

- Type: progress
- Attention: active
- Status: active
- Scope: current-stage
- Tags: focus, current, stage

## Doing Now

Stage 9 closes the foundation and shared permission contract gaps found
by the execution audit. Runtime schemas reject invalid arguments before
approval or execution. Sensitivity/effect metadata now enforces approval,
and opted-in out-of-project buffer reads use a call-specific approval
predicate. User plugin loading is allowlisted and ordered before startup.
Canonical suite: 564 tests passing.

## Not Doing Now

- No DI kernel or contribution-point framework
- No destructive branch truncation UI beyond existing explicit truncate helpers
- Mail sending remains intentionally disabled; daily mail support is
  draft-only
- User plugin files under `~/.chat/plugins/` stay off unless
  `chat-plugin-load-user-directory` is set

## Immediate Next Step

Complete the remaining kernel stream contract, cancellation propagation,
and resource-access scheduler before advancing to session behavior.
