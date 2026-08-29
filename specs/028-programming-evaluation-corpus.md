# Programming Evaluation Corpus

- Status: accepted design
- Scope: coding-agent evaluation
- Owners: coding Eval, verification, language profiles

## 1. Purpose

The programming evaluation corpus is a reusable repository asset. It defines
what a coding task means, which languages are covered, how a result is judged,
which generated artifacts are allowed, and which evidence is retained. A model
conversation or a one-off successful demo is not an evaluation corpus.

The corpus has two independently versioned manifests:

- the **core comparison manifest** keeps the established 30 tasks: Emacs Lisp,
  Python, JavaScript, Go and Rust, with six task categories per language;
- the **extended language manifest** adds Zig, Clojure, Java, TypeScript, C,
  C++ and SQL, with the same six categories per language.

The combined qualification suite therefore contains 12 languages and 72 tasks.
Keeping two manifests protects measurement identity: a result from the original
30-task baseline remains directly comparable, while the 42-task extension can
evolve under its own digest and baseline. This is an evaluation boundary, not a
runtime compatibility path.

## 2. Durable Assets

The repository keeps all reusable inputs and selected conclusions:

| Asset | Canonical location | Retention rule |
|---|---|---|
| Manifest and task wording | `tests/fixtures/coding-eval/` | Versioned; task identity changes when behavior changes |
| Fixture source and tests | `tests/fixtures/coding-eval/` | Small, deterministic and dependency bounded |
| Runner and judges | `lisp/agent/chat-coding-eval.el` | Product code with unit and integration tests |
| Acceptance thresholds | This spec and the active reliability plan | Stable until an explicit design revision |
| User operation guide | `docs/code-mode-usage.md` | Updated with public commands and recovery steps |
| Significant campaign analysis | `.agents/30-records/logs/` | Curated evidence, failures and decisions only |
| Raw live campaign data | Session evaluation storage | Immutable but not committed when large or sensitive |

Raw transcripts, provider payloads, credentials and disposable build output do
not enter Git. A stage record may quote bounded, privacy-safe metrics and exact
task IDs so a later developer can reproduce the conclusion.

`tests/fixtures/coding-eval/README.md` is the stable human entry point. It keeps
the language registry, reusable task wording patterns, verdict vocabulary and
retention boundary next to the executable corpus. A manifest cannot refer to a
sample that exists only in a local evaluation directory or an old transcript.

## 3. Task Matrix

Every language has exactly one task in each category:

1. `locate-explain`: locate a symbol or query and explain missing-value behavior;
2. `single-file-fix`: repair one implementation file;
3. `multi-file-change`: change behavior and its adjacent contract or documentation;
4. `refactor`: extract a named helper while preserving behavior;
5. `failing-test-fix`: repair implementation against a fixed failing test;
6. `read-only-review`: identify a seeded correctness defect without editing.

Task prompts are executable acceptance wording. They state the requested
behavior, mutation boundary and read-only status where applicable. They do not
tell the Agent which edit to make or include the hidden judge assertion.

The extended language profiles use these deterministic local toolchains:

| Language | Project shape | Targeted judge | Generated paths |
|---|---|---|---|
| Zig | package-free source and tests | `zig test` with a test filter | `.zig-cache`, `zig-out` |
| Clojure | dependency-minimal Lein project | `lein test :only` | `target`, `.lein-failures`, `.cpcache` |
| Java | source plus explicit test harness | `javac -d` then `java -cp` | `.chat-eval-build/java` |
| TypeScript | local compiler plus dependency-free Node test | `tsc --noEmit` then `node --test` on a named test | none |
| C | C17 source plus test harness | `clang` then a named harness case | `.chat-eval-build/c` |
| C++ | C++20 source plus test harness | `clang++` then a named harness case | `.chat-eval-build/cpp` |
| SQL | SQLite schema, query and assertion script | `sqlite3 :memory:` | none |

The manifest stores argv arrays, never shell fragments. A campaign records the
exact executable path and version discovered by preflight. Missing tools, an
uncached dependency or an unsupported version blocks the campaign before the
first provider request; it is never converted to a skipped or passing task.

## 4. Fixture Contract

Each fixture is a small standalone project with:

- a stable fixture ID and digest;
- source, tests and short local instructions needed to understand the project;
- no network dependency during setup, Agent execution or judging;
- one pre-existing unrelated defect only when the task explicitly tests bounded
  verification; otherwise the fixture starts from a single known task defect;
- deterministic setup and judge commands with finite timeouts;
- explicit `allowedPaths` and non-overlapping `generatedPaths`;
- a clean workspace after success, failure, timeout and cancellation.

Representative manifest fragment:

```json
{
  "id": "java-refactor",
  "revision": 1,
  "category": "refactor",
  "language": "java",
  "fixtureId": "java-sample-v1",
  "fixture": "java",
  "prompt": "Refactor normalizeName by extracting whitespace cleanup into a private helper named cleanName. Preserve behavior.",
  "allowedPaths": ["src/Sample.java"],
  "generatedPaths": [".chat-eval-build/java"],
  "timeoutSeconds": 120,
  "judges": [
    {
      "type": "command",
      "name": "normalize-tests",
      "command": ["sh", "test-one", "normalize"],
      "expectedExit": 0
    },
    {
      "type": "file-regexp",
      "name": "helper-extracted",
      "path": "src/Sample.java",
      "regexp": "cleanName"
    }
  ]
}
```

The example uses a fixture-owned bounded wrapper because compile-and-run needs
two processes. The wrapper contains fixed argv, writes only to its declared
build directory and accepts only an enumerated test case. It is fixture code,
not an Agent-generated shell command.

Typical project fragments remain in the fixture itself rather than being copied
into prose. A fixture should make language semantics observable: integer
division for C/C++/Zig, checked exceptions or optionals for Java, immutable data
transforms for Clojure, static shape preservation for TypeScript, and NULL,
ordering and transaction behavior for SQL.

## 5. Artifact Cleanup

Generated output is temporary evidence, not corpus content.

1. Every command that can write files declares all output roots in
   `generatedPaths`.
2. Judges run inside a session-owned copied workspace, never in the canonical
   fixture directory.
3. The runner removes declared generated paths immediately after each trial and
   removes the complete copied workspace at trial close.
4. Campaign close scans for owned processes, worktrees and build roots. Any
   residue fails cleanup and is reported separately from model correctness.
5. Integration tests compare workspace size and status before setup and after
   cleanup. Repeating a fixture must not increase repository disk usage.
6. Shared user caches are neither selected as output directories nor deleted by
   the runner. Fixture wrappers redirect writable caches into declared local
   roots when the toolchain requires one.

## 6. Acceptance Procedure

Development qualification has four gates:

1. **contract gate**: manifest schema, task/category balance, path safety and
   fixture digests pass;
2. **offline gate**: every fixture can setup, execute every judge and clean up
   without a provider call;
3. **focused live gate**: one mutation task per added language passes with the
   fixed provider/model/capability snapshot;
4. **repeated live gate**: all 42 extended tasks run three times for development
   and five times for final qualification.

The final extended campaign contains 210 unique trials. It reports every
language and category separately. Overall success must reach 90% or improve at
least 15 percentage points over the same-manifest baseline; every language must
reach at least 80% and must not regress from its baseline. Out-of-scope writes,
false verified completion and cleanup residue must all be zero.

The core 30-by-5 comparison and the extended 42-by-5 qualification remain
separate immutable campaigns. A combined report may summarize 360 trials, but
must not average away a failing language or substitute one manifest for the
other.

### 6.1 Acceptance Record

Every significant campaign record includes:

- campaign ID and role, implementation revision and clean-tree state;
- provider, concrete model, capability snapshot and configuration digest;
- manifest path, manifest digest, task revisions and expected sample count;
- valid, passed, failed, cancelled, timed-out, errored and quarantined counts;
- per-language and per-category rates, safety violations and cleanup residue;
- latency and token metrics when the provider exposes trusted usage;
- exact failed task identities, root-cause class and whether a code, prompt,
  fixture or infrastructure change followed;
- a final `PASS`, `FAIL`, `BLOCKED` or `INVALID` verdict using the repository
  vocabulary in the fixture README.

Large raw results remain in session evaluation storage. The committed record is
a bounded audit index, not an unauditable claim and not a copy of sensitive
provider traffic.

## 7. Language-Specific Optimization

Language detection distinguishes repository, current-file, target and planned
languages. A filename or user preference alone cannot activate hard validation.
The generic Agent loop remains complete without a language prompt pack.

An observed language issue is promoted only after repeated evidence:

- deterministic syntax, generated-path and toolchain facts become code;
- recurring strategy guidance becomes a versioned, bounded soft prompt pack;
- project-only conventions stay in scoped project instructions;
- a one-off failure remains a stage record until reproduced.

Each promotion records affected task IDs, before/after results, counterexamples,
token cost and a removal condition. This prevents a larger corpus from turning
into a larger collection of unmeasured prompt folklore.

## 8. Completion Checklist

- [ ] Extended manifest contains 42 tasks: seven languages by six categories.
- [ ] Combined corpus contains 72 unique task IDs and 12 languages.
- [ ] All toolchains have bounded, offline preflight and recorded versions.
- [ ] Every writing judge declares generated paths and passes repeated cleanup.
- [ ] File detection, language profile and verification adapters cover all 12 languages.
- [ ] Semantic quality fixtures report each supported language independently.
- [ ] Focused live smoke passes once per added language.
- [ ] Baseline and current extended campaigns each contain 210 valid trials.
- [ ] Per-language, overall, safety and cleanup thresholds all pass.
- [ ] Significant results and accepted prompt/code changes have durable stage records.
