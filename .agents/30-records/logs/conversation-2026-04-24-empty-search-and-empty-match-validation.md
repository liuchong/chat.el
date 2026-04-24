# Empty Search And Empty Match Validation

- Type: logs
- Attention: records
- Status: complete
- Scope: stage
- Tags: replace, regexp, validation, tests

## Summary

This stage hardened replace operations against two dangerous input classes: empty literal search strings and regexps that can match empty text.

## Changes

- rejected empty literal search text before replace execution
- rejected regexps that can match empty text before replace execution
- kept invalid regexp reporting stable
- added regression coverage for replace and patch paths leaving files unchanged on those failures

## Verification

- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- canonical batch regression baseline after this stage: `338` passed, `0` skipped, `0` failed

## Remaining Gap

- repository-wide tests-to-runtime-lines ratio is still far below the requested three-to-one target
