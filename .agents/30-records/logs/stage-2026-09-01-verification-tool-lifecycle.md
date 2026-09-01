# Verification Tool Lifecycle

- Type: logs
- Attention: records
- Status: complete
- Scope: programming verification tool contract
- Tags: verification, provider-menu, resource-id, session, task, eval

## Trigger

The C++ DeepSeek live smoke on revision `3bb4ff6` called
`programming_verification_run` before creating a verification profile. The tool
was valid and authorized, but its required Profile ID did not yet exist, so the
call failed with `Unknown verification profile` before the Agent recovered by
planning verification.

This was a system contract failure, not evidence that the model could not use
verification. The provider menu had advertised `plan`, `run` and `read_result`
as one group even though their inputs form a strict resource chain.

## Correction

- Every profile resolution now receives a unique opaque runtime handle. A
  project configuration name is no longer reused as a cache key.
- Profile ownership is recorded by session and Agent task. Verification results
  use the same ownership boundary through their parent Agent task.
- Provider visibility follows the resource chain: `plan`, then `run`, then
  `read_result`. Activating the verification capability uses the same staged
  selector and cannot expand the complete authority set prematurely.
- Empty deterministic plans expose the generic compile fallback but not `run`.
- Direct calls with a handle from another task fail closed even if they bypass
  the provider-facing menu.

## Test Method

The new tests first failed against the old implementation on all three observed
contracts: premature menu exposure, non-unique project profile IDs and missing
scope lookup. The implementation was then changed until the same tests passed.
The focused suite also covers restored plans, bounded skips, capability
activation, empty-plan fallback and execution-session ownership.

## Reusable Lesson

Authorization answers whether an Agent may ever use a capability. Advertisement
answers which operation is meaningful now. Treating these as one list makes the
model guess runtime-owned IDs and converts a deterministic state transition into
provider variance. Any tool that consumes an ID returned by another tool should
be hidden until that exact typed resource exists in the current scope, and the
executor must independently enforce the same ownership rule.

This live Eval again validated the long-goal workflow: preserve the failed run as
diagnostic evidence, classify whether the cause belongs to model behavior or the
shared runtime, repair the common layer with a regression test, then rerun the
same provider pair on one clean revision. A failed sample is therefore an input
to the next plan revision, not a reason to keep sampling unchanged code.

## Verification

- lifecycle TDD probes: 3/3 failed before implementation, then 3/3 passed;
- focused verification and capability suite: 63/63 passed;
- canonical suite: 1979 total, 1977 passed, 0 unexpected failures and 2 known
  Rust execution-isolation skips;
- `git diff --check` passed and no `.elc` or `.eln` artifacts remained;
- the C++ and SQL dual-provider reruns remain the next clean-revision Eval
  evidence and are intentionally separate from this implementation stage.
