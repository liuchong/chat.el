# Patch Newline And Move

- Type: logs
- Attention: records
- Status: complete
- Scope: stage
- Tags: patch, newline, move, tests

## Summary

This stage tightened patch-engine behavior around codex-style add-file newline semantics and move-path safety.

## Changes

- accepted `*** End of File` after `*** Add File` payloads
- preserved the default trailing newline for add-file operations when no EOF marker is present
- added explicit regression coverage for successful move updates
- added explicit regression coverage for atomic refusal when a move target already exists

## Verification

- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- canonical batch regression baseline after this stage: `308` passed, `0` skipped, `0` failed

## Remaining Gap

- repository-wide tests-to-runtime-lines ratio is still far below the requested three-to-one target
