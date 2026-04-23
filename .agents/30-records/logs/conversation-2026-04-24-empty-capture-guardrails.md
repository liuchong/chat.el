# Log Item

- Type: logs
- Attention: records
- Status: completed
- Scope: empty-capture-guardrails
- Tags: tests, reading, empty, guardrails, correctness

## Summary

Expanded regression coverage around blank-context reading captures and fixed two real defects: empty files were accepted by `current-file` and `near-point` capture paths and could produce empty quoted code blocks.

### Technical Decisions

- Kept the stage focused on shared helper guardrails instead of adding more command surfaces
- Treated empty-file capture acceptance as a runtime defect because it produces blank reading prompts with no useful context
- Fixed the guardrail at the shared reading helper layer so both plain chat and code mode inherit the behavior

### Completed Work

- Added regression tests for empty-file `current-file` capture rejection
- Added regression tests for empty-file `near-point` capture rejection
- Added shared-helper validation so blank code is rejected before a capture is returned
- Updated README, project status, and `.agents` records

### Verification

- Ran `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- Expected baseline after this stage: `272` regression tests run, `272` passed, `0` skipped, `0` failed

### Remaining

- The repository-wide tests-to-runtime-lines ratio is still far below three-to-one
- Shared reading workflow still has room for more prompt-shape and cross-buffer coverage
- Plain chat reading commands still do not have dedicated source-buffer key bindings
