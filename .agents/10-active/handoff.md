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

- M9-M19 are complete and revision-bound; never reuse their campaign evidence
  for M20 product changes
- Goal state is the completion contract; work plan/TODO is the execution path;
  Plan Mode is a permission boundary. Do not merge these concepts or stores
- Delayed model switching is implemented in `48b5350`: prepared prompt model,
  active request model and pending continuation model remain distinct
- M20 has an independent 42-task manifest covering Zig, Clojure, Java,
  TypeScript, C, C++ and SQL across six balanced categories
- Campaign preflight checks manifest-declared hidden toolchain dependencies as
  well as direct command executables before any provider request
- Zig, Java, C, C++ and SQL pass the reusable fixture semantic verifier
- The complete offline gate is blocked by missing `lein` and `tsc`; never turn
  this into skipped trials or silently shrink the matrix
- Campaign schema v2 stores invocation paths, canonical targets and versions in
  the immutable configuration digest and rejects drift on resume
- Project verification adapters for the seven languages remain incomplete
- Run exact-model live work only after the offline gate: DeepSeek
  `deepseek-v4-flash` and Kimi Code `k3-256k` use separate campaign identities
- Never use `k3`, aliases or K2.7 evidence for Kimi qualification
- The detailed current record is
  `stage-2026-09-01-versioned-toolchain-provenance.md`

## Avoid

- Creating a development worktree; the user directed development on `master`
- Creating new session records in `docs/ai-contexts/`
- Treating imported legacy logs as a substitute for current active focus files
