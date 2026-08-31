# Model Identity Integrity

- Date: 2026-08-31
- Status: deterministic verification complete; post-fix live verification pending
- Scope: Agent Run identity, request evidence, coding Eval validity

## Incident

The Kimi usage dashboard showed a `k3-256k` readiness request followed by K2.7
task requests. The frozen campaign descriptor was correct, but the shared Agent
Run stored only the provider symbol. A later configuration reload restored the
provider default, so the real task transport did not inherit the campaign's
concrete model.

`rerun-kimi-code-k3-256k-3e38e49-20260831-r1` passed its two code judges but is
invalid as K3 evidence. Earlier Kimi campaigns that claimed exact `k3-256k`
without per-request identity are reclassified as identity-unverified. They may
remain incident evidence for common runtime behavior, but cannot qualify K3,
promote a model adaptation or support a cross-provider comparison. Earlier
DeepSeek results also require fresh post-fix evidence for strict exact-model
acceptance, even where the provider default happened to match the requested
model.

## Root Cause

One field carried two meanings:

- provider symbol: adapter, protocol and endpoint;
- concrete model string: remote model selected for the request.

Readiness pinned both values, while the Agent task path retained only the first.
Campaign metadata therefore described intent rather than proving execution.

## System Contract

1. Every Agent Run has separate immutable `provider` and concrete `model`
   fields.
2. The concrete model is resolved once before dispatch from the explicit Run
   config, a matching session pin, or the provider default.
3. Initial, retry, tool-follow-up and steering requests force the Run model
   after all other request options are composed.
4. Profiles, configuration reloads, follow-up options and child execution
   cannot replace an active Run's identity.
5. Every real transport start emits `model-request-started` with provider,
   model and request id.
6. Session wire and request diagnostics retain actual request identity.
7. Coding Eval requires at least one request-identity record and rejects any
   missing or mismatched identity as an error, independently of code judges.

## Lesson

A requested model, a readiness request and a provider default are three
different facts. Exact-model acceptance must be based on the identity at every
actual task transport boundary. A passing behavioral judge cannot repair an
invalid measurement identity.

## Verification

The complete canonical batch passed 1911/1911 with zero skipped or unexpected
results when run with the full Rust toolchain PATH. The Agent end-to-end suite
passed 3/3. Focused tests prove model pinning across follow-up options, provider
override resolution, child identity propagation, actual-request wire records
and Eval rejection of identity drift.

Live results will be added after the implementation revision is clean and
committed. The live matrix is limited to `deepseek/deepseek-v4-flash` and
`kimi-code/k3-256k`; K2.7 and `k3` are excluded.
