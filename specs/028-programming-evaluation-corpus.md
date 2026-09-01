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

`manifest-large-repo.json` and the mutation-smoke manifests are measured
subsets, not additional behavioral corpora. The first contains the exact
`python-locate` task from the core manifest and runs it five times for each
implementation. `manifest-extended-mutation-smoke.json` contains exactly the
seven `failing-test-fix` tasks from the extended manifest and retains their
combined offline preflight and toolchain contract. Each
`manifest-<language>-mutation-smoke.json` contains the same canonical task for
one extended language and only that task's external executables. These focused
manifests allow an available language to be preflighted and compared without
silently skipping another language whose toolchain is absent. Unit gates
require byte-for-structure task equality with the canonical mutation smoke,
exact corpus IDs and exact per-language executable lists. This keeps focused
evidence reproducible without introducing a runtime task filter whose hidden
selection could diverge from the recorded manifest digest.

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
| Machine-readable language inventory | `tests/fixtures/coding-eval/language-registry.json` | Versioned; distinguishes executable and planned cohorts |
| Fixture source and tests | `tests/fixtures/coding-eval/` | Small, deterministic and dependency bounded |
| Acceptance playbook and examples | `tests/fixtures/coding-eval/ACCEPTANCE.md` | Stable run sequence, wording and cleanup checklist |
| First-request footprint baseline | `tests/fixtures/coding-eval/request-footprint-baseline.json` | Frozen historical measurement and explicit regression ceiling |
| First-request footprint runner | `tests/performance/run-request-footprint.el` | No-network capture at the real transport boundary |
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

The JSON registry is the authoritative language inventory. It records all 12
accepted language IDs and separates `executable` from `planned`; a planned
language is not a skip, pass or tested capability. Registry unit tests keep the
core cohort identical to the languages actually present in `manifest.json` and
keep every cohort bound to the same six accepted categories.

### 2.1 First-Request Footprint Contract

Provider tool schemas are request content and therefore part of the coding
Agent's performance surface. The offline gate measures the first request after
the actual profile, context and provider schema builders have run. Its metric is
the sum of UTF-8 message-content bytes and serialized provider-tool JSON bytes.
It deliberately excludes HTTP framing and credentials so the result is stable,
reviewable and runnable without network access.

The M9 baseline is frozen in `request-footprint-baseline.json`. Current code may
retain broader authority while advertising only the stage-relevant tool menu;
advertisement must never grant authority or bypass a disabled tool. The current
footprint must remain at or below 110 percent of the frozen baseline before a
live comparison revision is accepted. A threshold change is a design change
that requires an updated spec and stage analysis, not a campaign workaround.

### 2.2 Frozen Campaign Runtime Contract

Every campaign runs under a dedicated runtime HOME. The evidence directory and
trusted credential setup path are resolved before isolation, but provider
defaults, sessions, caches and state from the developer HOME are never read.
An automatically allocated runtime HOME is deleted when the runner exits. An
explicitly configured runtime HOME is retained only as bounded investigation
evidence and must not be committed.

Historical comparison executes implementation behavior from the exact frozen
checkout while loading the immutable campaign and result contract from the
current harness. The harness reloads and verifies both the generic Eval result
serializer and the coding campaign orchestrator after loading the historical
implementation. A frozen implementation may therefore provide Agent, tool and
transport behavior, but it cannot control result bounding, persistence, resume
identity or final campaign validation. This boundary is governed by explicit
protocol versions for:

1. binding provider and concrete model to an Agent run;
2. observing normalized request events at the model transport boundary;
3. projecting the implementation's declared capability schema.

The current implementation uses the current protocols directly. A frozen
implementation may use only a named, tested evaluation adapter for a protocol
version that it actually implements. Unknown versions block before campaign
creation. An adapter cannot enter ordinary application execution, consult a
mutable provider default, or fabricate a capability absent from the frozen
schema. This is reproducible-evaluation infrastructure, not a product
compatibility path.

The authoritative request identity is the normalized transport `started`
event. Its provider, concrete model and request ID are captured for every
initial request, retry and follow-up. Agent turn counts and requested campaign
configuration are not substitutes for observed transport identity. A missing
event, missing identity field or any provider/model drift fails the trial closed.

Each side retains its exact raw capability snapshot. Cross-revision comparison
derives a stable capability identity from model-facing fields present in every
accepted schema: stream, tools, tool choice, reasoning, structured output,
context window and output-token limit. Serializer version, provenance and a
new implementation-only runtime feature are evidence but not frozen model
identity. Any disagreement in a stable field remains a comparison failure.

Asynchronous executors expose a typed terminal-evidence handle. Its snapshot
operation freezes bounded answer, request identity, usage and execution counts;
its cancel operation stops the underlying run only after that snapshot. Eval
records the authoritative outer terminal intent before calling either one, so
a synchronous cancellation callback cannot replace task `timed-out` with Agent
`cancelled` or erase in-flight evidence. A synchronous executor returns nil
after completion. Ambiguous callable or result-shaped return values are invalid.

Final aggregation revalidates this contract independently for every live
terminal status. Request count must be positive and equal the number of stored
request identities. Every identity must have a request ID and match the frozen
executor provider/model. Missing or drifting evidence is infrastructure-invalid
and cannot satisfy the required sample matrix, even when the code judge passed.

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
| Clojure | dependency-minimal Lein project | `lein with-profile -base test :only` | `target`, `.lein-failures`, `.cpcache` |
| Java | source plus explicit test harness | `javac -d` then `java -cp` | `.chat-eval-build/java` |
| TypeScript | local compiler plus dependency-free Node test | `tsc --noEmit` then `node --test` on a named test | none |
| C | C17 source plus test harness | `clang` then a named harness case | `.chat-eval-build/c` |
| C++ | C++20 source plus test harness | `clang++` then a named harness case | `.chat-eval-build/cpp` |
| SQL | SQLite schema, query and assertion script | `sqlite3 :memory:` | none |

The manifest stores argv arrays, never shell fragments. A campaign records the
exact executable path and version discovered by preflight. Missing tools, an
uncached dependency or an unsupported version blocks the campaign before the
first provider request; it is never converted to a skipped or passing task.
The combined mutation manifest is the all-language gate and therefore requires
every extended toolchain. A focused language manifest is the independent smoke
gate and requires only that language's declared executables. It does not weaken
or partially pass the combined gate: unavailable focused manifests remain
explicitly blocked, while available manifests retain their own immutable
campaign identity and provider-separated evidence.
The Clojure fixture removes Leiningen's implicit `:base` profile during judging
so offline qualification depends only on the fixture project, not unrelated
interactive-tool dependencies. Product verification continues to execute the
project's declared `lein test` authority and does not inherit this fixture-only
evaluation policy.
The manifest-level `requiredExecutables` list names every external executable
used behind a fixture wrapper. Preflight resolves the union of that list and
the first argv item of every command judge. A wrapper such as `sh test-one`
must never make a missing compiler, runtime or test runner appear available.
Each supported executable has one fixed, no-network version command with a
five-second upper bound. The resolved record is sorted by executable name and
contains the absolute invocation path, its canonical target and bounded version
output. The probe runs through the invocation path so multi-call binaries and
version-manager shims preserve their command identity. Unknown
version probes fail closed even when an executable with that name exists.
Version evidence contains only normalized child stdout and stderr; editor
process lifecycle messages, sentinels and buffer diagnostics are not child
identity and must never enter the configuration digest.
Campaign schema v2 stores this record in `campaign.json` and includes it in the
configuration digest. Resume repeats preflight and rejects path or version
drift before scheduling a missing trial. Earlier campaign schemas are not
migrated or resumed.
An optional manifest-level `preflightChecks` array declares bounded argv checks
that run from the manifest directory after toolchain resolution and before
provider readiness. Each check's first executable must already have versioned
toolchain evidence. The extended corpus uses this gate to prove all seven
fixture baselines, seeded defects, cached dependencies and cleanup behavior in
the isolated runtime HOME. A failure or timeout blocks without creating a model
trial.
Every command judge start is also a terminal boundary: a process creation
failure records the command, a `not-started` result and the underlying error.
Any later synchronous evaluation failure records an explicit error result and
cleans the workspace. No evaluator exception may cancel the task timer and
leave the campaign waiting without durable terminal evidence.

### 3.1 Product Verification Adapter Boundary

The ordinary coding runtime and the Eval corpus share language names but not
command authority. Eval judges are fixture-owned. Product verification resolves
commands in this order:

1. `chat-code-verify-profile-function` supplied by the embedding application;
2. the project's `.chat-verification.json` declaration;
3. deterministic adapters whose required project marker is present;
4. no step, reported as `not-run`, when no authority is sufficient.

The deterministic adapters use the following minimum evidence:

| Ecosystem | Required authority | Generated step |
|---|---|---|
| Zig | `build.zig` declares a literal `test` build step | `zig build test` |
| Clojure | `project.clj` | `lein test` |
| Java | `pom.xml`, or a checked-in executable Gradle wrapper plus wrapper metadata | offline Maven test, or offline Gradle test |
| TypeScript | `tsconfig.json`, unless `package.json` already declares `typecheck` | project-local `tsc` when executable, otherwise `tsc --noEmit --project tsconfig.json` |
| C, C++, SQL | an exact top-level `test:` target in the Make authority selected by Make | `make test` |

Every generated step remains an argv array, required, bounded, project-rooted
and independently identified. A missing executable becomes `blocked` at
execution; it is not silently omitted or treated as a model failure. Source
suffixes, a `build.zig` without a test step, a Gradle file without a checked-in
wrapper, any unconfigured `deps.edn`, and a Makefile without an exact test target
do not authorize a command. C, C++ and SQL intentionally have no guessed
compile or query command because include graphs, link inputs, schemas and
assertion semantics are project facts.

## 4. Fixture Contract

Each fixture is a small standalone project with:

- a stable fixture ID and digest;
- source, tests and short local instructions needed to understand the project;
- no network dependency during setup, Agent execution or judging;
- one pre-existing unrelated defect only when the task explicitly tests bounded
  verification; otherwise the fixture starts from a single known task defect;
- deterministic setup and judge commands with finite timeouts;
- one explicit positive corpus task budget, inherited by every task unless that
  task declares a tighter positive override;
- explicit `allowedPaths` and non-overlapping `generatedPaths`;
- a clean workspace after success, failure, timeout and cancellation.

Representative manifest fragment:

```json
{
  "taskTimeoutSeconds": 300,
  "requiredExecutables": ["java", "javac"],
  "id": "java-refactor",
  "revision": 1,
  "category": "refactor",
  "language": "java",
  "fixtureId": "java-sample-v1",
  "fixture": "java",
  "prompt": "Refactor normalizeName by extracting whitespace cleanup into a private helper named cleanName. Preserve behavior.",
  "allowedPaths": ["src/Sample.java"],
  "generatedPaths": [".chat-eval-build/java"],
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
not an Agent-generated shell command. The actual manifest stores
`requiredExecutables` at its top level rather than repeating it on every task;
it is shown beside the representative task here to keep the dependency
contract visible.

The task budget is a correctness observation window, not a performance target.
The extended corpus uses the same 300-second window for every provider and
model. Reports still compare latency, request count and token use separately,
and reaching the window remains a failed trial. A task may declare a smaller
`timeoutSeconds` only when its own contract needs a tighter bound. Hidden
provider-specific timeout scaling is forbidden because it changes the measured
contract without changing the manifest identity.

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

`tests/fixtures/coding-eval/verify-extended-fixtures.sh` is the reusable offline
gate. It copies selected fixtures into a temporary workspace, verifies that the
known-good behavior passes, verifies that each seeded defect fails for the
expected semantic reason, and removes the workspace on every exit. Running it
without language arguments requires all seven toolchains; named language
arguments support bounded local diagnosis but do not satisfy the complete gate.

The final extended campaign contains 210 unique trials. It reports every
language and category separately. Overall success must reach 90% or improve at
least 15 percentage points over the same-manifest baseline; every language must
reach at least 80% and must not regress from its baseline. Out-of-scope writes,
false verified completion and cleanup residue must all be zero.

The core 30-by-5 comparison and the extended 42-by-5 qualification remain
separate immutable campaigns. A combined report may summarize 360 trials, but
must not average away a failing language or substitute one manifest for the
other.

The large-repository token gate additionally requires two completed focused
campaigns using `manifest-large-repo.json`: baseline 1-by-5 and current 1-by-5.
All ten trials must contain trusted first-request usage and at least 10,000
indexed fixture files. Their median comparison still requires at least a 15
percent reduction. The focused campaign cannot contribute to the behavioral
success rate or replace any core trial.

### 6.1 Acceptance Record

Every significant campaign record includes:

- campaign ID and role, implementation revision and clean-tree state;
- provider, concrete model, capability snapshot and configuration digest;
- the actual provider, concrete model and request id emitted for every real
  model request, not only the requested campaign identity;
- manifest path, manifest digest, task revisions and expected sample count;
- valid, passed, failed, cancelled, timed-out, errored and quarantined counts;
- per-language and per-category rates, safety violations and cleanup residue;
- latency plus first-request, final-request and total-task token metrics when
  the provider exposes trusted usage, including request count and coverage;
- an exact tool-error count plus bounded chronological records containing the
  Agent step, tool name, stable error type and a single-line summary; record
  and summary limits are explicit, and an omitted-record count preserves the
  difference between no error and truncated diagnostics;
- exact failed task identities, root-cause class and whether a code, prompt,
  fixture or infrastructure change followed;
- a final `PASS`, `FAIL`, `BLOCKED` or `INVALID` verdict using the repository
  vocabulary in the fixture README.

A trial without actual request-identity evidence is invalid. If any request
uses a provider or concrete model different from the frozen campaign pair, the
trial fails closed as an identity error and the campaign cannot contribute to
model qualification, adaptation evidence or cross-provider comparison.
These identity records and the task/campaign keys that bind them are protected
structural evidence: value bounding may truncate large diagnostic leaves but
must never collapse the enclosing metadata object or discard completion keys.

Token boundaries are explicit. `firstRequestTokenUsage` measures fixed prompt,
context-selection and provider-schema cost; `finalRequestTokenUsage` describes
the last model turn; `totalTokenUsage` is the sum across `requestCount` model
requests; `usageSampleCount` exposes provider coverage independently. The 110
percent fixed-overhead gate and the large-repository reduction
gate use first-request input tokens from all valid trials, regardless of task
correctness. Correctness failures remain failures in the success-rate gates but
do not erase an otherwise trustworthy performance sample. Infrastructure-
invalid attempts remain excluded from both correctness and token comparison.

Campaign token usage contains only the normalized numeric counters named by
this contract. Provider-specific raw usage objects remain transport diagnostics
and are not duplicated into task results. Result bounding applies independently
to scalar leaves, collection length and nesting depth; it may replace a large
diagnostic leaf with truncation evidence, but it cannot replace the enclosing
metadata object or erase task, campaign, provider, model or request identity.

Tool diagnostics follow the same rule. They never retain tool arguments, raw
results or exception objects. `toolErrorCount` remains exact;
`toolErrors` retains only a bounded public projection and
`toolErrorRecordsTruncated` reports records omitted by the collection limit.
This is enough to distinguish model recovery from a hidden infrastructure or
tool-contract failure after the disposable runtime HOME has been removed.

Large raw results remain in session evaluation storage. The committed record is
a bounded audit index, not an unauditable claim and not a copy of sensitive
provider traffic. Runtime result JSON is also structurally bounded: strings,
collection sizes and nesting depth are limited independently so a large answer
cannot erase the small identity facts needed for validation and resume.

New records start from
`.agents/templates/programming-evaluation-record-template.md`. This keeps the
identity, per-language results, token boundary, performance metrics, cleanup
evidence and standard verdict comparable across stages.

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

Language-specific guidance is one input to the model-adaptation policy defined
by `specs/029-model-adaptive-reliability.md`. Corpus tasks provide evidence; they
do not embed provider or model branches. The initial portability check runs the
same core manifest independently with DeepSeek `deepseek-v4-flash` and Kimi Code
`k3-256k`. Results retain separate campaign identities and are never pooled.

The Kimi matrix accepts only the concrete `k3-256k` identity. `k3`, model aliases
and a provider response resolving to a different model are invalid for this
qualification. This cost and identity constraint is part of preflight, before
any repeated live task is dispatched.

## 8. Completion Checklist

- [x] Extended manifest contains 42 tasks: seven languages by six categories.
- [x] Combined corpus contains 72 unique task IDs and 12 languages.
- [ ] All toolchains have bounded, offline preflight and recorded versions.
- [ ] Every writing judge declares generated paths and passes repeated cleanup.
- [x] File detection, language profile and verification adapters cover all 12 languages.
- [x] Semantic quality fixtures report each supported language independently.
- [ ] Focused live smoke passes once per added language.
- [ ] Baseline and current extended campaigns each contain 210 valid trials.
- [ ] Per-language, overall, safety and cleanup thresholds all pass.
- [ ] Significant results and accepted prompt/code changes have durable stage records.
