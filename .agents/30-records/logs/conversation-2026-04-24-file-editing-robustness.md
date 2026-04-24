# File Editing Robustness

- Type: logs
- Attention: records
- Status: complete
- Scope: stage
- Tags: files, editing, tests

## Summary

This stage hardened the core file editing helpers so they behave like real editing tools instead of thin demos.

## Changes

- `chat-files-write` now creates missing parent directories
- append mode now works when the target file does not already exist
- `chat-files-apply-patch` now plans all operations before touching disk, so later failures do not leave partial edits behind
- regexp replacements now use real `replace-match` semantics, which enables capture-group backreferences in both `files_replace` and `files_patch`

## Verification

- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- canonical batch regression baseline after this stage: `301` passed, `0` skipped, `0` failed

## Remaining Gap

- repository-wide tests-to-runtime-lines ratio is still far below the requested three-to-one target
