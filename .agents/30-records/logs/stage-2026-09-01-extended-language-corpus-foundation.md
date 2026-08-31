# Extended Language Corpus Foundation

- Date: 2026-09-01
- Scope: M20 deterministic corpus foundation
- Status: implementation complete; full offline and live gates pending

## Delivered Contract

The independent extended manifest now contains 42 stable task identities:
Zig, Clojure, Java, TypeScript, C, C++ and SQL each have locate/explain,
single-file fix, multi-file change, refactor, failing-test fix and read-only
review tasks. The immutable 30-task core manifest was not changed.

Every fixture is a dependency-minimal project with a bounded `test-one`
wrapper, explicit writable source paths and explicit generated paths. The
manifest declares the complete external executable set. Campaign preflight now
checks both those declared dependencies and direct command-judge executables
before any provider request. A shell wrapper can no longer hide a missing
compiler or test runner.

Language detection and source indexing now recognize all 12 corpus languages.
The extended cohort is marked executable because its fixtures and judges exist;
an unavailable local toolchain blocks a campaign rather than changing corpus
state or manufacturing a skipped result.

## Reusable Offline Gate

`tests/fixtures/coding-eval/verify-extended-fixtures.sh` copies fixtures into a
temporary workspace, checks the passing normalization behavior, checks that the
three seeded implementation defects fail, and removes the workspace on every
exit. It accepts language names for bounded diagnosis and requires all seven
languages when called without arguments.

The available local subset passed:

```text
zig java c cpp sql: normalize passed
zig java c cpp sql: divide, label and active defects failed as seeded
```

The complete invocation failed closed before execution with:

```text
BLOCKED: unavailable toolchains: clojure:lein, typescript:tsc
```

This is environment evidence, not a model failure and not a skipped corpus
result. No provider request was made in this stage.

## Verified Environment

- Zig 0.16.0
- Java and javac 21.0.12.1
- Node 26.7.0
- Apple Clang 21.0.0
- SQLite 3.51.0
- `lein`: unavailable on `PATH`
- `tsc`: unavailable on `PATH`

Exact executable paths and versions still need durable campaign-descriptor
storage before the toolchain completion gate can pass.

## Verification

- coding evaluation unit suite: 50/50 passed;
- extended manifest balance and fixture digest contract: passed;
- hidden wrapper dependency preflight: passed;
- 12-language detection assertion: passed;
- five available fixture profiles: passed with semantic seeded failures;
- canonical suite with the complete Rust toolchain `PATH`: 1,942/1,942 passed,
  zero skipped and zero unexpected;
- changed Lisp files byte-compiled successfully;
- generated fixture build roots: removed after verification.

The first canonical run had 1,940 passes and two Rust environment skips because
the process `PATH` omitted the installed rustup directory. Repeating the same
unmodified revision with that directory present produced 1,942/1,942. Isolated
legacy test files are not all self-loading; the repository-standard runner is
authoritative because it loads the complete module graph before ERT execution.

## Lessons

1. A judge command beginning with `sh` proves only that the wrapper can start.
   The manifest must declare dependencies used inside the wrapper so preflight
   can fail before provider work begins.
2. A fixture verifier must test both the known-good path and the intended seeded
   failures. A script that only expects zero exits cannot prove task semantics.
3. SQL views do not preserve source row identity. Deterministic assertions must
   expose and sort by stable semantic columns rather than an unavailable
   `rowid`.
4. Generated caches belong inside declared fixture roots. Zig caches are
   redirected to `.zig-cache`; compiled Java, C and C++ artifacts stay under
   `.chat-eval-build`.
5. Toolchain absence is a preflight blocker. It must not silently reduce the
   language matrix, consume repetition identities or become provider evidence.

## Remaining M20 Work

1. Provide deterministic `lein` and `tsc` executables, then pass the complete
   seven-language offline gate.
2. Persist exact resolved executable paths and versions in campaign descriptors.
3. Complete language-aware project verification adapters without guessing
   unsupported project commands.
4. Run one exact-model mutation smoke per language before repeated campaigns.
5. Run DeepSeek `deepseek-v4-flash` and Kimi Code `k3-256k` as separate
   immutable campaigns; never pool their per-language results.
