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

- M9-M18 and deterministic M19 implementation are complete; implementation
  revision `875433c` passes the canonical suite 1810/1810
- Goal state is the completion contract; work plan/TODO is the execution path;
  Plan Mode is a permission boundary. Do not merge these concepts or stores
- Clean runtime, quality and canonical JSON records are stored outside the
  repository and all production provenance gates pass for `875433c`
- Current and baseline no-network descriptors each contain 30 tasks, five
  repetitions and 150 expected results with the same frozen manifest
- M19 remains incomplete until fresh baseline/current live campaigns use one
  identical concrete provider/model identity and the strict aggregate passes
- DeepSeek Flash may be used, but it requires fresh campaign identities for
  both roles; never mix it with Kimi or historical campaign samples
- The provider transport boundary and bounded current-file reading were already
  complete when audited; do not reimplement them
- Privacy-safe Markdown session export is implemented in `8c14cff` and specified
  in `7b187fc`; use `M-x chat-export-session` or session-tree `e`
- Export is an allowlisted public projection, not a backup: never add prompts,
  reasoning, tool traffic, raw transport data, paths or arbitrary metadata to
  its default contract
- Development verification passes 1817/1817 canonical tests, 7/7 focused
  export tests and 4/4 documentation-contract tests

## Avoid

- Creating a development worktree; the user directed development on `master`
- Creating new session records in `docs/ai-contexts/`
- Treating imported legacy logs as a substitute for current active focus files
