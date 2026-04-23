# Read Lines Normalization

- Type: logs
- Attention: records
- Status: complete
- Scope: stage
- Tags: files, read-lines, tests

## Summary

This stage fixed inconsistent range metadata from `chat-files-read-lines` and added coverage for invalid and empty line-range requests.

## Changes

- added regression coverage for:
  - nonpositive start lines
  - empty requests with `num_lines` set to zero
  - requests that begin beyond EOF
- normalized `chat-files-read-lines` so the reported `:start` and `:end` values stay coherent even when the requested range is empty

## Verification

- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- canonical batch regression baseline after this stage: `289` passed, `0` skipped, `0` failed

## Remaining Gap

- repository-wide tests-to-runtime-lines ratio is still far below the requested three-to-one target
