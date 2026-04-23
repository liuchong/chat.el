# Open File Position Reporting

- Type: logs
- Attention: records
- Status: complete
- Scope: stage
- Tags: files, open-file, tests

## Summary

This stage added direct unit coverage for `chat-files-open-file` and fixed a real mismatch between requested line or column values and the actual landing position in Emacs.

## Changes

- added regression coverage for:
  - landing beyond EOF
  - landing past the end of a line
  - default point-min position reporting
- updated `chat-files-open-file` to return the actual line and column after movement instead of echoing the requested values

## Verification

- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- canonical batch regression baseline after this stage: `278` passed, `0` skipped, `0` failed

## Remaining Gap

- repository-wide tests-to-runtime-lines ratio is still far below the requested three-to-one target
