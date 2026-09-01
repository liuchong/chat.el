# M21 Rust Verification Runtime And Dual-Provider Diagnostic

Date: 2026-09-01
Revision under test: `f1719906f36d92734affe8ff0960c3976c72f7dc`
Status: focused diagnostic complete; full M21 qualification remains open

## Scope

This stage isolates the previously failing Rust multi-file task and answers two
questions without pooling provider results:

1. Can the restricted verification backend execute the declared Cargo command
   reliably with an isolated request environment?
2. Do exact `deepseek-v4-flash` and `k3-256k` identities both complete the same
   task after that common-layer repair?

The reusable task is
`tests/fixtures/coding-eval/manifest-rust-multi-file-diagnostic.json`, with
manifest digest
`0cd3420a273791beab8ad974ac661c6cca1480a9bb9da3478ff233c64a9542d3`.
Each provider used three independent repetitions and a 1,800 second campaign
deadline. Preflight fixed the implementation and harness revision, model,
manifest, result count and Cargo toolchain before any model request.

## Runtime Defects And Repair

The first direct stress run reproduced `Wrong type argument: arrayp, nil` in all
20 attempts. The cause was deterministic: an absent runtime-home value fell
through to an empty string, Emacs treated that as the current directory, and the
code later called `file-truename` with nil.

After correcting that path, the same probe exposed a second deterministic defect.
Canonicalizing `~/.cargo/bin/cargo` replaced the multicall entrypoint with its
`rustup` target. The backend consequently executed Cargo arguments as
`rustup test ...`.

The common execution layer now:

- resolves request and inherited environment values through one function;
- rejects empty environment values;
- canonicalizes a Rust runtime home only when it exists and is a directory;
- preserves the resolved executable entrypoint so multicall dispatch sees
  `cargo` as `argv[0]`.

The repaired restricted path completed the real targeted Cargo command 10/10.
Focused unit coverage includes inherited `RUSTUP_HOME`, absent developer `HOME`,
multicall symlink preservation and campaign runtime-home setup. The Eval unit
module passed 64/64.

## Independent Live Results

| Provider | Concrete model | Result | Duration ms | Requests | Tool calls | Tool errors |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| DeepSeek | `deepseek-v4-flash` | PASS | 37,004 | 11 | 16 | 0 |
| DeepSeek | `deepseek-v4-flash` | PASS | 57,247 | 17 | 24 | 1 |
| DeepSeek | `deepseek-v4-flash` | PASS | 50,457 | 16 | 23 | 2 |
| Kimi Code | `k3-256k` | PASS | 85,296 | 7 | 8 | 0 |
| Kimi Code | `k3-256k` | PASS | 104,896 | 11 | 12 | 0 |
| Kimi Code | `k3-256k` | PASS | 94,194 | 7 | 9 | 0 |

DeepSeek median duration was 50,457 ms and median request count was 16. Kimi
Code median duration was 94,194 ms and median request count was 7. These are
provider-local descriptive values, not one combined score.

Every recorded request used exactly its declared provider and concrete model.
All six runs:

- changed only `README.md` and `src/lib.rs`;
- passed the declared targeted Cargo judge;
- ended with a completed work plan carrying Evidence IDs;
- reported no out-of-scope file;
- cleaned the temporary workspace.

DeepSeek recovered from one rejected attempt to complete a non-active plan item
and, in a separate run, two malformed `files_patch` calls missing `search`.
Kimi Code produced no tool error in this sample.

## Policy Decision

No provider-specific policy is promoted from this stage. The shared tool schemas
already require `search` and `replace` for every legacy patch object, and shared
plan guidance already requires serial transitions of only the active item using
the returned revision. One three-run provider sample is insufficient to prove a
stable model-specific defect.

The two DeepSeek error shapes remain candidate observations. Promotion requires
repetition on a frozen manifest, a proposed policy with a measurable mechanism,
same-model A/B evidence and proof that the change does not weaken authority,
verification or path boundaries. A generic schema or runtime defect, if found,
must still be repaired in the common layer.

## Goal-Mode Lessons

This stage also exercised long-running Goal behavior in real development:

- a newly admitted follow-up did not silently replace the active objective;
- a deterministic blocker created a bounded recovery investigation instead of
  restarting the full matrix;
- the repair commit and focused campaigns updated checkpoint evidence without
  claiming Goal completion;
- provider results remained separately attributable while sharing one objective;
- queued requirements remain independently identifiable for closeout
  reconciliation.

These observations are normative in
`specs/027-session-collaboration-recall-and-admission.md` and the active Goal
design. The complete M21 campaign and final acceptance gates remain pending.

## Final Verification

The repository canonical suite completed after the record and Spec updates:

- 1,988 tests discovered;
- 1,986 passed;
- 0 unexpected results;
- 2 known environment skips for Rust system-SSL isolation.

No compiled Emacs artifacts remained in the repository, and no live campaign or
test process remained after collection.
