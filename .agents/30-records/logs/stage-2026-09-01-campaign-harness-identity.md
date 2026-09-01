# Campaign Harness Identity

- Type: stage-record
- Attention: reference
- Status: complete
- Scope: historical M20 campaign protocol and immutable evidence identity
- Date: 2026-09-01

## Discovery

The first historical final campaign stopped before model work because the
frozen product revision did not define a verification-contract function used by
the current campaign runner. A focused retry then reached the historical Agent
but exposed an interactive visiting-buffer supersession prompt. Both are
harness/product protocol differences, not model or task failures.

The runner now projects only protocols supported by the frozen product and
converts unattended supersession prompts into explicit fail-closed tool errors.
It does not edit, synchronize or otherwise repair historical product state.

During the retry preflight, the current harness revision changed while the
configuration digest remained equal. The descriptor recorded only the tested
implementation revision, so a campaign could have been resumed under different
runner semantics without detecting evidence drift. Execution stopped before a
provider request.

## Schema V3 Contract

Campaign schema v3 separates two immutable identities:

1. `implementationRevision` is the exact product checkout under test.
2. `harnessRevision` is the exact checkout providing the runner and evidence
   protocol.
3. Both fields, the manifest digest, exact provider/model identity, approval
   mode, repetition count and normalized toolchain record enter the canonical
   configuration digest.
4. Every durable trial result repeats both revision fields.
5. Resume validates both revisions before scheduling missing work.
6. Earlier schemas are not migrated or resumed.

A deterministic regression proves that changing only `harnessRevision` changes
the configuration digest. Another regression proves that resume rejects a
harness mismatch.

The focused campaign regression set passes 22/22. The complete canonical suite
reports 2023 expected passes, zero unexpected results and two existing
environment-isolation skips for system-SSL Rust execution. The canonical entry
intentionally returns nonzero when any test is skipped.

## Aborted Evidence

These campaign identities are infrastructure incident evidence only and must
never be resumed or pooled into final qualification:

- `m20-final-baseline-deepseek-049c4ef-ca3d203-r1`
- `m20-final-current-kimi-ca3d203-r1`

Focused protocol-smoke directories created under earlier harness revisions are
subject to the same rule. Fresh schema-v3 campaign IDs are required after the
harness revision is committed and frozen.

## Next Gate

Run one historical one-task smoke with distinct implementation and harness
revisions. Only after it reaches a durable bounded result may the four fresh
42-task by five-repetition final campaigns begin.
