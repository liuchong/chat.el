# Twelve-Language Semantic Quality

- Date: 2026-09-01
- Scope: M20 semantic indexing and quality evidence
- Status: complete
- Implementation revision: `c6fcd0babac8ed3fac628cf47abe2734c585d53c`

## Problem

The language detector named all 12 qualification languages, but source discovery,
fallback symbol extraction, repo-map admission and the immutable quality language
set did not agree. Several languages were therefore nominally supported while
their files or definitions could never reach the shared semantic pipeline.

## Contract

- All 12 languages use one source-discovery and repo-map path.
- Zig, Clojure, Java, C, C++ and SQL have bounded fallback declaration parsers;
  the existing JavaScript parser also receives an independent quality row.
- Fallback parsing records declaration categories without evaluating source or
  starting language services.
- C and C++ remain distinct: a C++ `class` is a class, and C rejects it.
- The quality-record language set is explicit and independently tested. Missing,
  duplicate or reordered language rows fail the existing acceptance gate.
- No provider, model or language branch enters the Agent loop.

## Failure-Guided Development

The first focused run passed 11 of 13 tests but found definitions for only 8 of
12 languages. Direct parser diagnostics isolated the missing Clojure, Java, C and
C++ declarations. The causes were identifier-boundary and declaration-regex
errors, not weak metric thresholds. The parsers were corrected and the original
gates retained. A final review then found that C++ classes were being labeled as
structs and the intended C-only filter could never match; a dedicated regression
test now fixes that distinction.

The reusable lesson is to test the complete path from admitted filename through
typed declaration and per-language metric row. A detector-only test can prove a
label while leaving the language unusable.

## Verification

- focused semantic, repo-map and acceptance tests: 16/16 passed;
- target byte compilation passed; generated `.elc` files were removed;
- canonical suite: 1955/1955 passed with zero unexpected results;
- clean-revision quality runner exited 0 on `c6fcd0b`;
- all acceptance gates passed and the tree was recorded clean;
- each of the 12 language rows reported definition accuracy, reference precision,
  reference recall and Top-5 hit rate of `1.0`;
- `git diff --check` passed before the implementation commit.

## Remaining M20 Work

1. Provide deterministic executable `lein` and `tsc` toolchains without implicit
   installation or network access.
2. Pass the complete seven-language offline setup, semantic, judge and cleanup
   gate.
3. Run one exact-model mutation smoke per language, then separate immutable
   DeepSeek `deepseek-v4-flash` and Kimi Code `k3-256k` campaigns.
