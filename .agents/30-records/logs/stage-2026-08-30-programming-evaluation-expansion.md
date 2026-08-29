# Stage - Programming Evaluation Expansion (2026-08-30)

## Scope

This stage records the accepted expansion of the reusable programming Eval
corpus. It does not implement or run the extended live campaign. M19 keeps its
fixed 30-task comparison; M20 adds an independently versioned 42-task language
qualification manifest.

## Accepted Matrix

The core matrix remains Emacs Lisp, Python, JavaScript, Go and Rust. The
extension adds Zig, Clojure, Java, TypeScript, C, C++ and SQL. Every language has
the same six task categories, producing 72 reusable tasks across 12 languages.

The repository now records the durable asset contract in
`specs/028-programming-evaluation-corpus.md`: fixture shape, task wording,
deterministic judges, path boundaries, cleanup, repeated live qualification,
result retention and promotion of language-specific rules.

## Local Toolchain Survey

The bounded preflight survey found:

| Toolchain | Observed local capability |
|---|---|
| Zig | `zig 0.16.0` |
| Java | OpenJDK and `javac 21.0.12.1` |
| TypeScript runtime | Node `26.7.0`; no standalone `tsc` found |
| C and C++ | Apple Clang `21.0.0` |
| SQL | SQLite `3.51.0` |
| Clojure | Leiningen `2.9.4`; no `clojure` or `clj` command found |

This survey is not a permanent minimum-version declaration. Every campaign must
record its own exact executable and version. In particular, Node's ability to
execute stripped TypeScript is not accepted as type checking; the TypeScript
qualification blocks until a local compiler passes preflight. Clojure fixtures
must prove that all dependencies are already available without network access.

## Cleanup Decision

Build and test output is temporary trial evidence. Every writing command has a
declared local output root, and the runner must remove it after the trial before
removing the copied workspace. Repeated integration tests compare status and
disk use before setup and after cleanup. Shared user caches are neither output
targets nor cleanup targets.

This keeps expanded language coverage from growing persistent `target`, class,
binary, cache or database output across campaigns.

## Next Work

1. Finish and freeze the M19 core comparison revision.
2. Add extended-manifest schema and balance tests.
3. Implement seven fixtures and six tasks per language in reviewable batches.
4. Extend detection, verification and semantic quality records from observed
   fixture requirements.
5. Pass offline repeated cleanup before the first provider call.
6. Run one focused mutation smoke per language, then baseline/current repeated
   campaigns without mixing results with the core manifest.
