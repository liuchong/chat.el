# Focus

- Type: progress
- Attention: active
- Status: active
- Scope: current-stage
- Tags: focus, current, stage

## Doing Now

Stage 10 closes the remaining kernel stream, scheduling, and in-flight
cancellation gaps found by the execution audit. Native tool deltas,
reasoning, stop reasons, and provider errors now share one stream result
contract. Resource-aware asynchronous batches preserve result order,
serialize writes and approvals, and cancel active tool handles.
Canonical suite: 569 tests passing.

## Not Doing Now

- No DI kernel or contribution-point framework
- No destructive branch truncation UI beyond existing explicit truncate helpers
- Mail sending remains intentionally disabled; daily mail support is
  draft-only
- User plugin files under `~/.chat/plugins/` stay off unless
  `chat-plugin-load-user-directory` is set

## Immediate Next Step

Close the remaining plugin runtime lifecycle and metadata persistence
details before advancing to session behavior.
