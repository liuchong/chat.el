# Extended Language Verification Adapters

- Date: 2026-09-01
- Scope: M20 product verification boundary
- Status: complete

## Problem

The extended Eval corpus had deterministic judges, but ordinary coding sessions
still lacked project verification adapters for Zig, Clojure, Java, TypeScript,
C, C++ and SQL. Copying fixture commands into product detection would have
confused fixture authority with arbitrary repository structure and created
false verification.

## Contract

Command authority remains ordered: embedding profile, project
`.chat-verification.json`, deterministic detection, then `not-run`. Detection
composes ecosystems and never branches the Agent loop by language.

- Zig requires a literal `test` step in `build.zig`.
- Clojure requires `project.clj`; a `deps.edn` alias alone cannot prove that a
  command executes assertions rather than only changing the classpath.
- Java uses offline Maven, or an executable checked-in Gradle wrapper with its
  wrapper metadata.
- TypeScript requires `tsconfig.json`, prefers the project-local executable
  compiler and does not duplicate a package `typecheck` script.
- C, C++ and SQL use only an exact top-level `test:` target selected by Make.

Source suffixes and incomplete build markers do not authorize guessed compile,
link, query or test commands. Missing executables become an explicit blocked
result at execution.

## Verification

- focused verification module: 24/24 passed;
- target byte compilation passed;
- canonical suite: 1,951/1,951 passed with zero skipped or unexpected results;
- `git diff --check` passed;
- macOS canonical-path behavior for project-local tools is asserted;
- positive marker, ambiguous marker, wrapper preference, duplicate TypeScript
  suppression and explicit project-config precedence are covered.

## Remaining M20 Work

1. Provide deterministic local `lein` and `tsc` toolchains; do not install or
   fetch them implicitly.
2. Pass the all-seven offline semantic and cleanup gate.
3. Run one exact-model mutation smoke per language, then independent immutable
   DeepSeek `deepseek-v4-flash` and Kimi Code `k3-256k` campaigns.
