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

- M17 runtime status, diagnostics, performance runner and strict gate code are complete
- Keep M17 blocked until isolated M9 baseline and M17 current campaigns each
  contain a comparable 30-by-5 live result set with trusted token usage
- The fixed tagged large-repository task now materializes 10,000 indexed files
- The M9 revision `e4e6cbc` passes a no-network current-harness preflight for
  30 tasks and 150 expected results when its inherited fixture limit is raised
  explicitly to 12,000; this is compatibility evidence, not live Eval evidence
- Reproduce the aggregate with `M-x chat-coding-acceptance-run-final`

## Avoid

- Creating new session records in `docs/ai-contexts/`
- Treating imported legacy logs as a substitute for current active focus files
