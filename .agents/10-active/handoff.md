# Handoff

- Type: progress
- Attention: active
- Status: active
- Scope: handoff
- Tags: handoff, stage, continuity

## Ready State

- `.agents/` is now the formal agent workspace
- Legacy `docs/ai-contexts/` session records were migrated into `.agents/30-records/logs/`
- `AGENTS.md` now routes agents through `.agents/`

## Continue With

- M17 durable Goal Mode and M18 read-only Plan Mode are complete; the canonical
  suite passes 1760/1760
- Goal state is the completion contract; work plan/TODO is the execution path;
  Plan Mode is a permission boundary. Do not merge these concepts or stores
- The isolated M9 baseline is complete with 150 terminal results: 3 passed,
  107 failed, 23 errored and 17 cancelled
- Keep M19 blocked until the comparable M19 current campaign contains its
  30-by-5 live result set with trusted token usage
- The fixed tagged large-repository task now materializes 10,000 indexed files
- The M9 baseline is bound to implementation revision `e4e6cbc`, provider
  `kimi-code`, model `k3` and the fixed manifest
- Reproduce the aggregate with `M-x chat-coding-acceptance-run-final`

## Avoid

- Creating new session records in `docs/ai-contexts/`
- Treating imported legacy logs as a substitute for current active focus files
