# Plan Gate And Campaign Closure

- Date: 2026-08-31
- Scope: M19 common Agent reliability and M21 cross-provider preparation
- Diagnostic implementation: `8ece6a5`
- Diagnostic campaign: `m19-diagnostic-deepseek-v4-flash-8ece6a5-r1`
- Tags: agent, plan, tools, evaluation, provider

## Findings

The clean diagnostic campaign completed 30/30 core tasks. It recorded four
`plan-required` events, all for `files_patch`. The previous diagnostic had 26
such events: 20 for `files_replace` and six for `programming_compile_task`.
Staging ordinary mutation and compile tools behind an active work plan removed
those 26 collisions, but the separately activated `batch-edit` capability still
advertised `files_patch` before a plan existed.

The same diagnostic sequence exposed two evaluation-infrastructure facts:

- a command judge whose executable is missing can fail synchronously before a
  process exists; terminal cleanup must not depend on a process sentinel;
- a provider transport failure can occur after valid trials. The code-56
  attempt was quarantined, the campaign remained resumable, and completed work
  was not duplicated or reclassified as model failure.

## Decision

Every mutation belongs to one common execution stage. `files_patch` is now an
ordinary execution tool, so it is authorized by the programming profile but is
advertised only after a non-Plan-Mode work plan has one `in-progress` item.
There is no separate `batch-edit` activation path and therefore no route around
the Plan gate. Read-only Plan Mode continues to expose no mutation tool.

Campaign startup validates all command-judge executables before any provider
request. Synchronous judge startup and evaluator post-processing failures write
terminal error evidence and release campaign ownership.

## Diagnostic Metrics

For the 30 valid `deepseek-v4-flash` trials at `8ece6a5`:

- status: 30 passed;
- latency: median 43,207 ms, p90 63,301 ms, maximum 73,758 ms;
- requests: 281 total, median 10, p90 15, maximum 18;
- tool errors: five;
- approvals: 106;
- total tokens: 1,587,218;
- provider attempts quarantined separately: one.

These values are diagnostic evidence, not the final current result, because the
common-layer implementation changed after the campaign.

## Verification

- capability and Plan staging tests: 31/31 passed;
- canonical suite with the complete toolchain: 1881/1881 passed, zero skipped
  and zero unexpected;
- no campaign or test process was left running.

## Next Qualification

Run fresh, immutable bounded core campaigns on the new clean revision using the
same manifest and common policy. The exact identities are DeepSeek
`deepseek-v4-flash` and Kimi Code `k3-256k`. `k3` is excluded. Report provider
attempts separately and compare language, task category, usage, latency, repair
and tool-contract behavior without pooling the two providers.

