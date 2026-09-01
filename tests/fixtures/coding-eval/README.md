# Programming Evaluation Fixtures

This directory is the repository-owned source of truth for repeatable coding
evaluation inputs. A task is eligible for a live campaign only when its prompt,
project fixture, deterministic judges, mutation boundary and cleanup contract
are all committed here.

Stable entry points:

- `language-registry.json` lists all 12 accepted languages, cohort, state,
  extensions and required toolchains in a machine-readable form;
- `manifest.json` defines the executable 30-task core corpus;
- `manifest-core-reliability-smoke.json` keeps the exact six M21 recovery tasks;
- `request-footprint-baseline.json` freezes the M9 first-request byte baseline
  and its 110 percent regression ceiling;
- `ACCEPTANCE.md` contains the repeatable run sequence, representative smoke
  cases, project fragments, cleanup checklist and standard verdict wording.

## Corpus Registry

| Manifest | Languages | Categories per language | Tasks | State |
|---|---|---:|---:|---|
| `manifest.json` | Emacs Lisp, Python, JavaScript, Go, Rust | 6 | 30 | executable core corpus |
| `manifest-core-reliability-smoke.json` | JavaScript, Go, Rust | observed failures only | 6 | focused cross-provider recovery gate |
| `manifest-extended.json` | Zig, Clojure, Java, TypeScript, C, C++, SQL | 6 | 42 | executable extended corpus |
| `manifest-extended-mutation-smoke.json` | all extended languages | 1 | 7 | combined mutation gate |
| `manifest-<language>-mutation-smoke.json` | one extended language | 1 | 1 | independent provider control |

The six categories are `locate-explain`, `single-file-fix`,
`multi-file-change`, `refactor`, `failing-test-fix` and `read-only-review`.
The two full manifests keep independent digests. Campaigns are comparable only
when their manifest digests match; historical 120-second core evidence is not
pooled with the current 300-second `coding-core-v2` corpus.

`verify-extended-fixtures.sh` runs copied fixtures only. With no arguments it
preflights all seven toolchains before execution; language arguments select a
bounded local subset while developing. A valid baseline must compile and pass
the normalization behavior check, while the divide, label and active checks
must each fail for their seeded task defect. The live Agent is then responsible
for making one selected mutation check pass inside its disposable workspace.

Only an `executable` cohort is eligible for preflight or live campaign
accounting. A missing toolchain blocks that campaign before provider use; it
does not change committed corpus state or count as a skipped task. Changing a
language ID, cohort or task category is a versioned corpus-design change and
requires registry tests plus a stage record.

The combined mutation manifest intentionally blocks unless all seven extended
toolchains are available. For incremental qualification, use the corresponding
focused manifest. Each focused manifest is unit-checked as an exact copy of its
canonical mutation task and declares only that language's executables. Passing
one focused campaign never changes another language's `BLOCKED` result and
cross-provider evidence remains separate.

`manifest-core-reliability-smoke.json` is unit-checked as an exact subset of
the six core tasks that failed the first exact-identity M21 control. It is the
bounded gate for a common-layer correction. Passing it does not replace a full
30-task core qualification.

The core, extended and focused manifests declare a shared 300-second correctness
observation window. The value participates in the manifest digest, is inherited
by every task unless that task declares a tighter bound, and is identical across
providers. Reports continue to preserve latency, request count and token use as
separate performance evidence; a timeout is still a failed trial.

## Reusable Task Shape

Every executable task keeps these assets together:

1. A stable task ID, revision, category, language and fixture ID.
2. Acceptance wording that describes behavior and edit scope without revealing
   the implementation or hidden assertion.
3. A small standalone project that works without network access.
4. Explicit `allowedPaths` and, for every possible build output,
   `generatedPaths`.
5. One or more deterministic judges with fixed argv and finite timeouts.
6. A cleanup result proving that generated files, copied workspaces and owned
   processes were removed after every terminal state.

Representative prompt patterns:

```text
Find <symbol purpose> and explain <edge-case behavior>. Do not edit files.
Fix <named behavior> while preserving <existing invariant>.
Change <behavioral contract> and update <adjacent contract file>.
Refactor <symbol> by extracting <detail> into <required helper>. Preserve behavior.
The <named test> fails. Fix the implementation, keeping the test unchanged.
Review <bounded behavior> for correctness. Name the risky symbol and explain the defect. Do not edit files.
```

These are patterns, not substitutes for committed manifest entries. Each final
prompt must name enough observable behavior to be unambiguous for its fixture.

## Acceptance Standard

A trial passes only when all applicable judges pass and all of these invariants
hold:

- the Agent reaches a terminal answer within the task budget;
- read-only tasks produce no edits;
- mutation tasks change only `allowedPaths`;
- the claimed verification is backed by the recorded judge result;
- no undeclared generated file or owned process remains;
- infrastructure failures are quarantined and do not claim a trial identity.

Standard compiler output belongs in `generatedPaths`, not in `allowedPaths` and
not in a prompt that discourages normal verification. For example, Emacs Lisp
mutation tasks declare `sample.elc`: it is audited and removed, while only the
source and explicitly requested documentation may count as product edits.

Campaign reports use one of these bounded verdict forms:

```text
PASS: <campaign-id> contains <valid>/<expected> unique valid trials at <revision>; all correctness, scope and cleanup gates passed.
FAIL: <campaign-id> is complete but failed <named gate>; <count> valid trials are affected. See <task IDs or stage record>.
BLOCKED: <campaign-id> produced no admissible conclusion because <preflight or infrastructure condition>; affected attempts were quarantined and trial identities remain pending.
INVALID: <campaign-id> cannot be compared because <identity, digest, revision, cleanliness or sample-integrity violation>.
```

Do not describe an incomplete, quarantined or identity-mismatched run as a
model failure. Do not describe a complete run as accepted unless every declared
gate is represented in the machine-readable aggregate.

## Typical Project Fragments

The current fixtures deliberately exercise a small shared behavior vocabulary:

- lookup and missing-value semantics;
- numeric division and zero handling;
- label generation plus adjacent documentation;
- whitespace normalization with a required helper extraction;
- state interpretation against a fixed failing test;
- exact administrator-role comparison for read-only review.

Language-specific fixtures should preserve category equivalence while exposing
real semantics of that language. Examples include integer rounding in Zig/C/C++,
immutable transforms in Clojure, checked compilation in Java and TypeScript,
and NULL, ordering or transaction behavior in SQL. The actual source and tests
must live beside the corresponding manifest, not only in design prose.

## Evidence Retention

Commit small reusable assets and curated conclusions:

- manifests, generators, fixture sources, tests and bounded wrappers;
- schema tests, acceptance thresholds and public run instructions;
- first-request baselines and offline measurement runners that execute the real
  request builder immediately before transport;
- significant stage records with campaign identity, revision, configuration
  digest, sample counts, per-language/category metrics and failure analysis;
- accepted prompt, rule or implementation adjustments with before/after task IDs.

Keep credentials, provider payloads, private transcripts, copied workspaces,
compiler output and large per-trial result sets outside Git. Stage records may
refer to their session-owned evidence location and must contain enough bounded
metadata to reproduce or audit the conclusion.

## Cleanup Rule

Never run a campaign against this canonical directory. The runner copies a
fixture into session-owned storage, redirects writable toolchain caches into
declared local roots, and removes those roots after every trial. Before and
after a campaign, compare repository status and disk use and scan for owned
processes, copied workspaces, build directories and temporary worktrees.

The complete design and final thresholds are in
`specs/028-programming-evaluation-corpus.md`.
