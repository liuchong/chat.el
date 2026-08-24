# Focus

- Type: progress
- Attention: active
- Status: active
- Scope: current-stage
- Tags: focus, current, stage

## Doing Now

Stage 13 closes work orchestration execution and resume gaps found by the
execution audit. Declarative workflows now execute ordered tool steps,
skip conditional steps deterministically, pause at approval checkpoints
or failures, and resume from persisted session state. Background task
completion emits a hook and optional notification.
Canonical suite: 578 tests passing.

## Not Doing Now

- No DI kernel or contribution-point framework
- Mail sending remains intentionally disabled; daily mail support is
  draft-only
- User plugin files under `~/.chat/plugins/` stay off unless
  `chat-plugin-load-user-directory` is set

## Immediate Next Step

Integrate MCP and sub-agent capabilities into the primary agent tool loop,
including request-panel lifecycle events and protocol-level tests.
