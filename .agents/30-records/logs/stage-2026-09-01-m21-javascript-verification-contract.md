# M21 JavaScript Verification Contract Diagnostic

Date: 2026-09-01
Revision under test: `e1d685d2578414ef4345151d15eaed20daacc3cb`
Status: focused diagnostic complete; full M21 qualification remains open

## Scope

This stage validates two common-layer repairs before restarting the 30-task
DeepSeek campaign:

1. an Agent-opened clean buffer changed by a file tool must refresh without an
   interactive prompt, while unsaved editor changes still fail closed;
2. an exact Eval command contract must override generic language detection, and
   the persisted result must prove which verification profile actually ran.

The reusable task is
`tests/fixtures/coding-eval/manifest-javascript-refactor-diagnostic.json`.
Its manifest digest is
`73b4239c32dab2a9700f76e573fe25a5ba1da42530dcb5b4a73ff1f3b2a6cdca`.
The language registry digest is
`9e6683a4447b99e42c6303214b03f26ef9e054defe216cd20b166c393699b1c2`.

## Frozen Identity

- Campaign: `m21-js-refactor-deepseek-e1d685d-r1`
- Role: current
- Provider/model: `deepseek/deepseek-v4-flash`
- Repetitions/expected results: 1/1
- Configuration digest:
  `15eceb9a8ed343f8c9df84384f03c17bcbc2bb031cad9ec0824c7fc94f3a69dd`
- Implementation and harness revision:
  `e1d685d2578414ef4345151d15eaed20daacc3cb`
- Worktree state at preflight and execution: clean
- Toolchain: `/opt/homebrew/bin/node`, Node `v26.7.0`

The ordered task request IDs were:

```text
request-1a05b5acfee-87a4d1eb0e09e5b
request-1a05b5ad549-1fdda5db692b0a22
request-1a05b5ada68-d477c345dfed215
request-1a05b5ae47e-e44f9f0bbc84466
request-1a05b5ae992-1a0fa3179f5ad68a
request-1a05b5aee98-18c0ea11fe5ac276
request-1a05b5b0148-1e9786f2ef6da62b
request-1a05b5b062f-1a0df1697c5bd6e9
request-1a05b5b0b5f-122900be69ed16f9
```

Every request reported the frozen provider and concrete model.

## Trial Result

| State | Count |
|---|---:|
| Expected | 1 |
| Valid | 1 |
| Passed | 1 |
| Failed | 0 |
| Cancelled | 0 |
| Timed out | 0 |
| Errored | 0 |
| Quarantined attempts | 0 |

The result duration was 18,067 ms, including 17,944 ms of Agent work. The Agent
made nine model requests and twelve tool calls. It changed only `sample.js`,
passed the declared `node test.js normalize` judge, reported no out-of-scope or
generated file, and cleaned its workspace. The final skip-plan projection was
completed at revision 2. Tool errors, stale writes and cleanup residue were all
zero.

The real path included one `open_file` call after mutation. It completed without
a minibuffer prompt, so this run covers the original noninteractive-buffer
regression rather than merely relying on a unit test.

## Verification Profile Evidence

The persisted executor metadata contains:

```text
source=runtime-contract
stepCount=1
contractCommandCount=1
contractDigest=f19e3cd58f2ed03fcacd175553270c0c0b39f4fd03c3f8da8881f3d12b28a70d
profileDigest=f19e3cd58f2ed03fcacd175553270c0c0b39f4fd03c3f8da8881f3d12b28a70d
exactContractMatch=true
```

The result deliberately does not duplicate raw argv. The frozen manifest owns
the exact command; equal ordered-command digests and counts prove the resolved
runtime profile matched it.

## Usage And Diagnostics

| Metric | Value | Coverage |
|---|---:|---:|
| First-request input tokens | 1,439 | 1/1 |
| Final-request input tokens | 6,955 | 1/1 |
| Total-task input tokens | 40,839 | 1/1 |
| Total-task output tokens | 1,977 | 1/1 |
| Model request count | 9 | 1/1 |
| Usage sample count | 9 | 1/1 |
| Tool call count | 12 | 1/1 |
| Tool error count | 0 | 1/1 |
| Approval count | 2 | 1/1 |

These values describe one diagnostic and are not a model-performance baseline.

## Deterministic Verification

- Verification-profile projection and executor metadata path: covered in the
  coding Eval unit module.
- Coding Eval unit module: 66/66 passed.
- Canonical suite on the clean tested revision: 1,996 discovered, 1,994 passed,
  0 unexpected, 2 known Rust system-SSL environment skips.
- Repository compiled Emacs artifacts: none.
- Campaign/test process residue: none.

The strict canonical runner reports non-success when any test is skipped; the
two skips are the pre-existing system-SSL isolation cases, not regressions from
this change.

## Decision

The two defects belong to the common layer. They are deterministic contracts,
not evidence for a provider-specific policy:

- editor state decides whether a stale visiting buffer may refresh;
- an exact task verification contract outranks inferred language defaults;
- Eval closure requires direct proof that the resolved profile matched the
  frozen contract.

No provider-specific prompt or tool policy is promoted. The next admissible
step is a fresh 30-task DeepSeek core-v2 campaign on the newest clean revision.
The incomplete 17-result campaign from the superseded revision remains incident
evidence and cannot be resumed or merged into the new matrix.

## Retained Evidence

- Repository record: this file.
- Runtime campaign directory:
  `/Users/liu/.chat/evaluations/m21-js-contract-e1d685d/m21-js-refactor-deepseek-e1d685d-r1`
- Result:
  `eval-20260901T050451240594000-b8ece0.json`

## Verdict

```text
PASS: m21-js-refactor-deepseek-e1d685d-r1 contains 1/1 unique valid trial at e1d685d; exact runtime-contract selection, noninteractive file refresh, correctness, scope and cleanup gates passed.
```
