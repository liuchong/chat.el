# Staged Programming Tool Contracts

- Date: 2026-08-30
- Scope: M19 request footprint and provider tool advertisement
- Baseline revision: `e4e6cbcec89a8a0d5f67d15a861ace9d9b4965d3`
- Implementation parent: `4377a9f`
- Tags: agent, tools, performance, acceptance

## Problem

The completed `f0b0701` paired campaign proved a large fixed input-token gap.
An offline reconstruction at the real transport boundary isolated the cause:
the current code profile sent every authorized programming tool schema on the
first request, even when most lifecycle tools could not be relevant yet.

| Measurement | M9 baseline | Before | After |
|---|---:|---:|---:|
| Advertised provider tools | 19 | 47 | 19 |
| Message-content bytes | 238 | 609 | 609 |
| Provider-tool JSON bytes | 6,086 | 20,289 | 5,996 |
| Combined bytes | 6,324 | 20,898 | 6,605 |
| Ratio to baseline | 1.0000 | 3.3046 | 1.0444 |

The before result violated the unchanged 1.10 gate. The after result passes it.

## Design

The code profile retains all 48 authorized programming tools. Authority and
advertisement are separate contracts:

- the initial menu contains 19 tools needed for repository inspection, normal
  edits, bounded task startup and explicit capability activation;
- Plan, Goal, work-note, verification, context and batch-edit groups are exposed
  only after activation;
- an active durable Plan or Goal restores its own lifecycle tools on the next
  run;
- activation mutates only the ephemeral execution session and cannot add a tool
  outside profile authority or revive a disabled tool;
- direct calls to authorized but unadvertised tools fail closed;
- empty parameter descriptions are omitted from provider JSON, while meaningful
  descriptions are preserved.

This reduces repeated schema input without weakening the coding Agent. It also
keeps the provider contract honest: the model only sees tools it may call in the
current stage.

## Reusable Evidence

- frozen baseline: `tests/fixtures/coding-eval/request-footprint-baseline.json`
- offline runner: `tests/performance/run-request-footprint.el`
- operator contract and verdict wording:
  `tests/fixtures/coding-eval/ACCEPTANCE.md`
- corpus and metric semantics: `specs/028-programming-evaluation-corpus.md`

The runner uses the committed `elisp-single-fix` task, the real code profile and
request builder, and a mocked transport. It writes bounded JSON when
`CHAT_REQUEST_FOOTPRINT_OUTPUT` is set and removes its copied workspace.

## Verification

- focused agent-profile, tool-caller and capability tests: 92/92 passed;
- first-request footprint: 6,605 / 6,324 bytes = 1.0444, passed;
- provider requests made by the footprint runner: 0;
- temporary workspace residue: 0.

## Remaining Work

This stage does not complete M19. Freeze a clean implementation revision, rerun
the deterministic reliability records, then create fresh baseline/current
30-by-5 campaigns. The live token metric and large-repository comparison still
need a validity rule that does not make a failed historical correctness trial
the sole source of performance evidence.

PASS: first-request footprint is 6,605 bytes versus 6,324 bytes (1.0444x),
within the 1.10x gate; 19 tools were advertised.
