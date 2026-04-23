# Lesson Item

- Type: lessons
- Attention: records
- Status: active
- Scope: tests
- Tags: batch, default-directory, process-file

## Lesson

Batch Emacs runs can inherit an invalid `default-directory`, and external tool execution will fail far away from the code that actually introduced the bad state.

## Why It Matters

- The failure often appears as a `diff` or `process-file` error instead of a clear setup error
- Test isolation that only changes `HOME` is not enough

## Guard

- Bind external process execution to a known valid directory
- Keep the canonical batch test runner responsible for isolated state roots
