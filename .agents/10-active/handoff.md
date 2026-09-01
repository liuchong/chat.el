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
- The complete 42-task offline fixture, judge and cleanup gate is closed; five
  exact-model focused qualifications pass independently for Zig, Java, C, C++
  and SQL
- Campaign preflight checks manifest-declared hidden toolchain dependencies as
  well as direct command executables before any provider request
- All 12 qualification languages enter source discovery, fallback symbol
  indexing, repo-map projection and independent semantic quality rows
- TypeScript and Clojure focused qualification and the complete repeated matrix
  are blocked by missing independent `tsc` and `lein`; never turn those cells
  into skipped trials or silently shrink the matrix
- Campaign schema v2 stores invocation paths, canonical targets and versions in
  the immutable configuration digest and rejects drift on resume
- Project verification adapters cover the seven extended ecosystems using
  explicit project authority and fail closed on ambiguous markers
- Zig requires a declared build test step; Clojure requires Lein; Java uses
  offline Maven or a checked-in Gradle wrapper; TypeScript
  avoids duplicate package typechecks; C/C++/SQL require exact `make test`
- Run exact-model live work only after the offline gate: DeepSeek
  `deepseek-v4-flash` and Kimi Code `k3-256k` use separate campaign identities
- Never use `k3`, aliases or K2.7 evidence for Kimi qualification
- M21 is complete: both exact providers passed the same core-v2 manifest 30/30,
  and no provider-specific policy was promoted without causal A/B evidence
- The latest detailed record is
  `stage-2026-09-01-zig-dual-provider-qualification.md`
- Specs 031-034 now record the deferred subscription, remote scoped-rule,
  distributed/headless runtime and collaborative-group designs. They are design
  authorities only; do not describe them as implemented or insert them into M20
  qualification work.

## Avoid

- Creating a development worktree; the user directed development on `master`
- Creating new session records in `docs/ai-contexts/`
- Treating imported legacy logs as a substitute for current active focus files
