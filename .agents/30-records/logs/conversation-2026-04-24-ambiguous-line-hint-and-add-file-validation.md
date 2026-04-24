# Ambiguous Line Hint And Add File Validation

- Type: logs
- Attention: records
- Status: complete
- Scope: stage
- Tags: replace, patch, validation, tests

## Summary

This stage tightened two easy-to-miss AI editing failure shapes: ambiguous same-line replace attempts and malformed add-file payloads.

## Changes

- added regression coverage showing `line_hint` does not silently choose among multiple matches on one line
- added regression coverage showing add-file patch payloads must keep the `+` prefix on content lines
- confirmed both failure paths leave on-disk state untouched
- kept the runtime unchanged while expanding the canonical failure matrix

## Verification

- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- canonical batch regression baseline after this stage: `335` passed, `0` skipped, `0` failed

## Remaining Gap

- repository-wide tests-to-runtime-lines ratio is still far below the requested three-to-one target
