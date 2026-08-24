# Focus

- Type: progress
- Attention: active
- Status: active
- Scope: current-stage
- Tags: focus, current, stage

## Doing Now

Stage 11 closes the remaining plugin lifecycle and metadata persistence
gaps found by the execution audit. Mixed owned resources share one
reverse-chronological rollback stack, replaced registrations are restored,
and teardown errors cannot leak resources. Persisted tools retain their
permission metadata and parameter enumerations.
Canonical suite: 571 tests passing.

## Not Doing Now

- No DI kernel or contribution-point framework
- No destructive branch truncation UI beyond existing explicit truncate helpers
- Mail sending remains intentionally disabled; daily mail support is
  draft-only
- User plugin files under `~/.chat/plugins/` stay off unless
  `chat-plugin-load-user-directory` is set

## Immediate Next Step

Complete durable session branching, compaction, append durability, and
interrupted-run recovery behavior.
