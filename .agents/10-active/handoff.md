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
  suite passes 1782/1782
- Goal state is the completion contract; work plan/TODO is the execution path;
  Plan Mode is a permission boundary. Do not merge these concepts or stores
- The isolated M9 baseline is complete with 150 terminal results: 3 passed,
  107 failed, 23 errored and 17 cancelled
- `m19-current-20260829T022800` is complete at revision `aa4698a`: 112 passed,
  37 cancelled and one failed, with no transport or framework errors
- Keep M19 incomplete: the measured 74.67 percent success rate misses the 80
  percent floor, five cancelled Rust trials leaked temporary files outside the
  allowed paths, and the M9 baseline lacks trusted token usage for 10/150 trials
- The interrupted `m19-current-20260828T210105` attempt contains only the first
  30/150 terminal results at revision `8c45301` and no completion record; keep it
  as incomplete evidence and do not mix it into the post-change campaign
- `m19-current-20260828T220053` reached 150/150 at revision `8ca4ae8`, but 131
  DNS and two TLS failures left 133 infrastructure-invalid trials; retain it as
  incident evidence and never use it for the final comparison
- New live campaigns support validated missing-trial recovery through
  `chat-coding-eval-resume-live`; resume rejects revision, manifest, capability,
  runtime, duplicate-result and concurrent-run drift
- Model transport retries use cancellable `2/5/10/20s` backoff. Exhausted
  transient failures move to `attempts/`, release the lock and leave the trial
  missing for a later resume
- The fixed tagged large-repository task now materializes 10,000 indexed files
- The M9 baseline is bound to implementation revision `e4e6cbc`, provider
  `kimi-code`, model `k3` and the fixed manifest
- Generic verification now accepts a run identity, and compile-task commands
  use the same deterministic exact command gate as background tasks; unknown
  commands still fail closed
- Run a fresh current campaign after further fixes, then reproduce the aggregate
  with `M-x chat-coding-acceptance-run-final`; do not reuse the `aa4698a`
  campaign after the implementation revision changes

## Avoid

- Creating new session records in `docs/ai-contexts/`
- Treating imported legacy logs as a substitute for current active focus files
