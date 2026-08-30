# Programming Evaluation Record

- Type: logs
- Attention: records
- Status: draft
- Scope: coding-evaluation
- Tags: evaluation, acceptance, evidence

## Identity

- Date:
- Campaign role:
- Campaign ID:
- Implementation revision:
- Harness revision:
- Clean tree:
- Provider and model:
- Capability/configuration digest:
- Manifest path and digest:
- Language registry digest:
- Repetitions and expected trials:

## Environment

| Toolchain | Executable | Version | Preflight |
|---|---|---|---|

## Trial Results

| State | Count |
|---|---:|
| Expected | |
| Valid | |
| Passed | |
| Failed | |
| Cancelled | |
| Timed out | |
| Errored | |
| Quarantined attempts | |

Record per-language and per-category counts without replacing them with one
overall average. Record out-of-scope writes, false verified completion and
cleanup residue explicitly, including zero.

## Performance And Cost

| Metric | Value | Coverage | Gate |
|---|---:|---:|---|
| Input tokens | | | |
| Output tokens | | | |
| Latency median | | | |
| Latency p95 | | | |
| Main-loop max slice | | | |
| Warm query p95 | | | |
| Incremental update | | | |

Do not synthesize missing usage as zero. Name the exact request boundary used by
each token metric and keep baseline/current definitions identical.

## Deterministic Evidence

- Runtime reliability:
- Semantic quality:
- Canonical suite:
- Focused regression tests:
- Cleanup scan:

## Failure Analysis

List exact task IDs, repeated symptoms, evidence-backed root cause, the code,
prompt, fixture or infrastructure action taken, and any counterexample that
prevents over-generalizing the fix.

## Retained Evidence

List only bounded repository records and privacy-safe immutable local evidence
locations. Do not paste transcripts, provider payloads or generated workspaces.

## Verdict

```text
PASS|FAIL|BLOCKED|INVALID: <standard bounded verdict>
```

## Remaining Work

-
