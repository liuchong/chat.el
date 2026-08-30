# First-Request Token Accounting

- Date: 2026-08-30
- Scope: M19 live token and large-repository acceptance semantics
- Implementation parent: `37aa6b5`
- Tags: eval, tokens, large-repo, acceptance

## Finding

The live executor replaced its `tokenUsage` value after every model request.
The durable result therefore retained only the final request even though the
gate described general input cost. The large-repository gate also selected only
passed tasks. A valid historical trial that failed correctness could provide a
trustworthy first-request usage value, but the gate erased that evidence and
reported the performance comparison as blocked.

## Correct Contract

Every live trial now records four independent facts:

- `firstRequestTokenUsage`: fixed prompt, selected context and initial provider
  tool schema;
- `finalRequestTokenUsage`: the last model request after any tool loop;
- `totalTokenUsage`: counters summed across model requests;
- `requestCount`: the number of model requests.

`requestCount` comes from model turn starts; `usageSampleCount` separately
records provider coverage. A total counter is emitted only when every usage
sample contains that counter, so a missing value is never synthesized as zero.

The 110 percent fixed-overhead gate and the large-repository 15 percent
reduction gate use first-request input tokens from all valid trials. Correctness
status remains part of success-rate acceptance and is never softened. Only
infrastructure-invalid attempts are inadmissible for both dimensions.

The offline footprint record now includes implementation revision, clean-tree
state and measurement time. Final aggregation validates its baseline identity,
recomputes its ratio and binds it to the exact current campaign revision.

## Verification

- coding Eval and acceptance tests: 64/64 passed after final aggregation wiring;
- failed-but-valid large-repo baseline usage remains comparable;
- a 10x larger final request does not change a passing first-request gate;
- missing baseline first-request coverage remains blocked;
- altered footprint ratios and revision mismatch remain blocked.

## Remaining Work

Run the complete focused suite after the final source gate is connected, commit
on `master`, then produce clean revision-bound runtime, quality, canonical and
request-footprint records before starting fresh 30-by-5 campaigns.
