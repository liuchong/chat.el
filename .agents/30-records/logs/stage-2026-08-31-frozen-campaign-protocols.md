# Frozen Campaign Protocols

- Date: 2026-08-31
- Harness revision: `16cccd1a9506dabc8a6ca40e07cb470d1b47b4f8`
- Baseline revision: `e4e6cbcec89a8a0d5f67d15a861ace9d9b4965d3`
- Provider/model: `deepseek/deepseek-v4-flash`
- Tags: evaluation, model-identity, protocol, isolation, baseline

## Root Cause

The frozen baseline did not share three current implementation contracts. Its
Agent used `:model` for the provider, its normalized model runtime had no
request-observer option, and its capability schema did not declare
`reasoningReplay`. It also read the developer runtime HOME. Treating those
differences as implicit current behavior either lost the concrete model,
polluted the frozen run with mutable user state, or fabricated historical
capabilities.

## System Decision

Agent configuration, normalized request observation and capability projection
now have explicit protocol versions. The ordinary product path uses current
protocols directly. The batch campaign harness recognizes only declared frozen
versions and installs narrowly scoped evaluation adapters; unknown versions
fail before campaign creation. Adapters never enter ordinary application
execution.

Every campaign uses an isolated runtime HOME. Evidence and trusted setup paths
are resolved before isolation. Implicit runtime directories are removed at
exit; an explicit directory is retained only for investigation.

Actual request identity comes only from normalized transport `started` events.
Every initial request, retry and follow-up records provider, concrete model and
request ID. Missing evidence or drift fails closed. Raw capability snapshots
remain intact. Final comparison derives a stable model capability identity from
fields shared by accepted schemas, while any disagreement in those shared
fields remains a comparison failure.

## Verification

- protocol and acceptance tests: 91/91 passed;
- integration: 3/3 passed, two credential-gated Kimi cases skipped by design;
- E2E: 3/3 passed;
- complete canonical suite: 1922/1922 passed, zero unexpected;
- current clean preflight: 30 tasks, five repetitions, 150 expected, manifest
  `0164487205a6fab51be67eebdfb9d7dad48ec7c68ccadb20b513c2da5e344dcc`,
  configuration
  `b4acc7e3dbb3d5d6c8096faa3ac9f8af71dda62a514b9dd7eb1db476e09bdf98`;
- baseline clean preflight: the same task matrix and manifest, configuration
  `722b792a9138e5e60b7243cdca9114f25acd3c2657472ef5190048b4f9be0880`.

The current one-task live smoke passed. All three task requests recorded exact
`deepseek/deepseek-v4-flash` identities. The frozen baseline smoke completed
normally and all four requests recorded the same exact identity. Its content
judge failed because the historical streaming implementation produced damaged
text and omitted the complete symbol name. That is valid baseline capability
evidence, not an identity or campaign-infrastructure failure.

## Remaining Gate

These one-task smokes prove the request and evidence path but cannot contribute
to the final 30-by-5 comparison. M19 remains open until fresh baseline and
current 150-trial campaigns complete on this exact clean harness revision and
the final acceptance aggregator passes every gate.
