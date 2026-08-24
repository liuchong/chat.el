# Focus

- Type: progress
- Attention: active
- Status: active
- Scope: current-stage
- Tags: focus, current, stage

## Doing Now

Stage 14 closes primary-loop MCP and sub-agent integration gaps found by
the execution audit. Configured servers connect lazily and register
discovered schemas as namespaced tools. Nested agents use isolated child
sessions and the shared kernel; subprocess agents exchange JSONL. Shared
approval, async cancellation, and request lifecycle events remain intact.
Canonical suite: 585 tests passing.

## Not Doing Now

- No DI kernel or contribution-point framework
- Mail sending remains intentionally disabled; daily mail support is
  draft-only
- User plugin files under `~/.chat/plugins/` stay off unless
  `chat-plugin-load-user-directory` is set

## Immediate Next Step

Complete the missing programming, office, and daily capability tools and
their profile-level integration tests.
