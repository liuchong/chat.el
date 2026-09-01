# Programming Evaluation Acceptance Playbook

This playbook is the repeatable operator contract for the repository-owned
coding corpus. It complements the machine-readable manifests: the manifests
define trial identity and judges, while this file defines how a developer runs,
classifies, records and cleans an acceptance campaign.

## Stable Inputs

Before any provider request, freeze and record:

- implementation revision and clean-tree state;
- harness revision;
- provider, concrete model and capability snapshot;
- one actual request-identity record per model request, containing provider,
  concrete model and request id;
- manifest path, digest and task revisions;
- language registry path and digest;
- behavioral manifest and, when measuring repository scale, the exact focused
  large-repository manifest digest;
- repetition count, timeout and campaign role;
- executable paths and toolchain versions.

`language-registry.json` is the canonical inventory. A language marked
`executable` must have committed fixtures and manifest tasks. A language marked
`planned` is part of the accepted qualification design but must not be counted
as tested, skipped or passed.

## Reusable Acceptance Cases

Every language uses the same six behavioral cases. Concrete core examples are
kept in `manifest.json`; these representative task IDs are the quickest smoke
set:

| Case | Representative task | Required evidence |
|---|---|---|
| Locate and explain | `python-locate` | named symbol, correct missing-value behavior, no edits |
| Single-file fix | `elisp-single-fix` | bounded source diff plus passing behavior judges |
| Multi-file change | `javascript-multi-file` | implementation and adjacent contract both updated |
| Refactor | `go-refactor` | required helper exists and observable behavior is preserved |
| Failing-test fix | `rust-failing-test` | fixed implementation, unchanged test and passing judge |
| Read-only review | `python-review` | grounded risky symbol and defect explanation, no edits |

The fixture projects are also the canonical project-fragment examples:

- `elisp/sample.el` and `elisp/sample-test.el` demonstrate source plus ERT;
- `python/sample.py` and `python/test_sample.py` demonstrate source plus unittest;
- `javascript/sample.js` and `javascript/test.js` demonstrate a dependency-free Node project;
- `go/sample.go` and `go/sample_test.go` demonstrate package-scoped Go tests;
- `rust/src/lib.rs` and `rust/Cargo.toml` demonstrate a small Cargo library;
- `python-large/src/account_status.py` plus its generator definition demonstrate
  the 10,000-file repository lookup case without committing generated files.

Do not copy a fragment into a temporary prompt and call that a new fixture. A
new acceptance case receives a stable ID, a committed project, deterministic
judges, path boundaries and cleanup declarations.

### Quiet Background Verification Control

At least one mutation smoke must use a successful compile or test command that
writes no standard output. The Agent must read `programming_task_output` once,
observe `terminal=true`, `status="succeeded"`, `exitCode=0` and `output=""`,
then continue to its final verification decision. Repeating the same command or
polling the same complete output solely because the output string is empty is a
contract failure, even when the fixture judge later passes.

Run this control separately for every exact provider/model under comparison.
Do not pool the results: differences in tool use, Guard decisions, request
count, latency or completion behavior remain provider/model evidence. A batch
runner reaching its own terminal state does not make the contained trial pass;
the persisted trial status and all judges remain authoritative.

## Execution Sequence

1. Validate registry and manifest schema, balance, task identity and fixture digests.
2. Run every fixture and judge offline in copied session-owned workspaces.
3. Run one focused mutation smoke for each newly executable language.
4. Diagnose and correct code, prompt, fixture or infrastructure defects before
   starting a repeated matrix.
5. Run immutable baseline and current campaigns with identical manifest,
   provider, model, capabilities and repetition count.
6. Run the exact one-task large-repository manifest five times for both frozen
   implementations; do not use it as behavioral success evidence.
7. Run deterministic runtime, quality, canonical and performance evidence on
   the exact clean current revision.
8. Build the strict aggregate from raw machine-readable evidence.
9. Scan for copied workspaces, compiler output, owned processes and temporary
   worktrees; any residue is an acceptance failure.

The public batch commands and Emacs entry points are documented in
`docs/code-mode-usage.md`. Large live campaign output stays in session-owned
evaluation storage. It must not be copied into Git merely to make a result look
durable.

## Offline First-Request Footprint Gate

Run this no-network gate before freezing a live comparison revision. It loads
the real `elisp-single-fix` task, builds the actual code-profile request, captures
it immediately before transport, and compares message-content bytes plus the
provider-tool JSON bytes with `request-footprint-baseline.json`.

```sh
state=$(mktemp -d /tmp/chat-request-footprint-XXXXXX)
trap 'find "$state" -depth -delete' EXIT
HOME="$state/home" CHAT_REQUEST_FOOTPRINT_OUTPUT="$state/result.json" \
  /Users/liu/projects/.agent-tools/capped.sh 1600 \
  emacs -Q --batch -l tests/test-paths.el \
  -l tests/performance/run-request-footprint.el
```

The process exits 0 only when `passed` is true and `currentRatio` is at most the
committed `maxCombinedRatio`. The baseline is an immutable historical fact; a
larger intentional request contract requires a reviewed design revision and a
new comparison baseline, never an edit made only to turn a failure green.

Use one of these bounded statements in a stage record:

```text
PASS: first-request footprint is <current> bytes versus <baseline> bytes (<ratio>x), within the <limit>x gate; <tool-count> tools were advertised.
FAIL: first-request footprint is <current> bytes versus <baseline> bytes (<ratio>x), above the <limit>x gate; the live campaign revision is not frozen.
```

## Trial Standard

A trial is valid only when its frozen identity is unique and the provider
attempt was admissible. A valid trial passes only when all applicable judges
pass, writes stay within `allowedPaths`, claimed verification exists, read-only
tasks make no edits, and declared generated output is removed.

The requested campaign identity is not proof of the model actually used. Every
real request must report the same provider and concrete model as the frozen
trial. Missing request evidence or any mismatch is `INVALID`, even when the
task's code judges pass.

Infrastructure attempts that fail before admissible model work are quarantined.
They do not consume a repetition/task identity and do not become model failures.
Missing tools or dependencies block the relevant campaign before the first
provider request.

Use `manifest-<language>-mutation-smoke.json` for this focused step. The
manifest contains one task copied exactly from the combined mutation smoke and
only the external executables used by that language. Do not substitute a
runtime task filter or remove a missing tool from the combined manifest. Record
each unavailable focused manifest as `BLOCKED`, then continue only with other
independently identified manifests whose preflight passes.

For an M21 common-layer recovery, use
`manifest-core-reliability-smoke.json`. It contains the exact six task
identities that failed the first DeepSeek/Kimi control and inherits the shared
300-second correctness window. Run it independently with
`deepseek/deepseek-v4-flash` and `kimi-code/k3-256k`; do not substitute aliases
or pool their results. A passing recovery smoke proves only that the observed
failure set closed. Full core qualification remains pending until all 30
`coding-core-v2` tasks pass under the same manifest digest.

When a recovery task times out after successful tool calls but before mutation,
run `manifest-go-refactor-diagnostic.json` as an independent one-task campaign.
The result must retain the exact concrete model identity, `toolCallCount`, the
bounded `toolCallSummary`, its omitted-name count, request count, changed files
and cleanup outcome. This diagnostic is evidence for deciding the next common
or candidate policy; it is not a retry that can overwrite the failed recovery
trial.

When a recovery task changes all allowed files but ends with an open or blocked
work plan, run `manifest-rust-multi-file-diagnostic.json` independently. Inspect
`workPlanFinalState` together with the tool-call summary and deterministic
judges. The projection must contain only plan/item identifiers, revisions,
statuses, bounded evidence identifiers and bounded blocker text; it must not
copy objectives, titles, acceptance text or provider content.

When a task contract contains a more specific command than language detection,
run `manifest-javascript-refactor-diagnostic.json` independently before
restarting the full core campaign. Its verification profile must report
`source=runtime-contract`, `exactContractMatch=true`, equal contract/profile
digests and matching command/step counts. The result projection must not copy
raw argv; the manifest remains the authority for `node test.js normalize`.
The run must finish without a minibuffer prompt even when an Agent-opened file
changed on disk. This diagnostic closes only the exact-command and
noninteractive-open regression; it contributes no replacement trial to the
full campaign.

`manifest-large-repo.json` must remain an exact structural copy of the core
`python-locate` task. Its baseline and current campaigns each contain exactly
five unique repetitions. Final acceptance verifies that both focused campaigns
match their corresponding core implementation revision and that the pair uses
the same provider, concrete model, capability snapshot and focused manifest.

## Standard Verdict Wording

Use exactly one leading verdict and name the decisive evidence:

```text
PASS: <campaign-id> contains <valid>/<expected> unique valid trials at <revision>; all correctness, scope, cleanup and declared performance gates passed.
FAIL: <campaign-id> is complete but failed <gate>; <count> valid trials are affected. See <task IDs or stage record>.
BLOCKED: <campaign-id> produced no admissible conclusion because <preflight or infrastructure condition>; attempts were quarantined and trial identities remain pending.
INVALID: <campaign-id> cannot be compared because <identity, digest, revision, cleanliness or sample-integrity violation>.
```

Examples:

```text
PASS: core-current-r1 contains 150/150 unique valid trials at abc1234; all correctness, scope, cleanup and declared performance gates passed.
FAIL: core-current-r1 is complete but failed live-eval-first-request-input-token-budget; 150 valid trials are affected. See the M19 stage record.
BLOCKED: extended-smoke-r1 produced no admissible conclusion because the TypeScript compiler failed preflight; attempts were quarantined and trial identities remain pending.
INVALID: core-current-r1 cannot be compared because one real request used a model different from its frozen campaign identity.
```

Never soften `FAIL` to partial success, turn `BLOCKED` into a model defect, or
average away a failing language.

## Durable Result Record

Commit a bounded stage record when a campaign establishes a reusable baseline,
changes a design decision, exposes a repeated failure class, accepts a prompt or
code adjustment, or completes a milestone gate. Start from
`.agents/templates/programming-evaluation-record-template.md`.

Retain these facts:

- campaign and revision identity;
- requested identity and the ordered actual request identities;
- exact request count and request IDs for passed, failed, cancelled, timed-out
  and errored live trials; a terminal status never permits identity omission;
- manifest and configuration digests;
- expected, valid, passed, failed, cancelled, timed-out, errored and quarantined counts;
- per-language and per-category rates;
- scope, false-completion and cleanup counts;
- latency, request count, first/final/total trusted token statistics and sample
  coverage;
- deterministic suite counts and performance measurements;
- failed task IDs, root-cause class, action taken and remaining work;
- final standard verdict.

Do not commit credentials, transcripts, provider payloads, copied workspaces,
compiler output or large per-trial result sets. Record their bounded immutable
location only when it is privacy-safe and useful for local audit.

## Cleanup Checklist

- [ ] Canonical fixture files and manifest digest are unchanged by execution.
- [ ] Session-owned trial workspaces are removed.
- [ ] Every declared generated path is absent.
- [ ] No campaign-owned process remains.
- [ ] No temporary worktree remains.
- [ ] Repository status contains only intended source, fixture and record changes.
- [ ] Repeating offline setup and cleanup does not increase repository disk use.
