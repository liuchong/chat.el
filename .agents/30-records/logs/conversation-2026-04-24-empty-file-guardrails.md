# Log Item

- Type: logs
- Attention: records
- Status: completed
- Scope: empty-file-guardrails
- Tags: tests, reading, empty-file, guardrails, correctness

## Summary

Expanded guardrail coverage around empty-file reading captures and fixed the shared helper layer so `current-file` and `near-point` both reject files that contain no readable code.

### Technical Decisions

- Kept the stage focused on the shared reading helper layer so both plain chat and code mode inherit the same guardrails
- Treated empty-file capture acceptance as a runtime defect because it creates blank quoted prompts with no useful context
- Reused one helper validation path instead of scattering emptiness checks across individual command entry points

### Completed Work

- Added regression tests for empty-file `current-file` capture rejection
- Added regression tests for empty-file `near-point` capture rejection
- Added shared validation so blank code is rejected before a capture object is returned
- Updated README, project status, and `.agents` records

### Verification

- Ran `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- Expected baseline after this stage: `272` regression tests run, `272` passed, `0` skipped, `0` failed

### Remaining

- The repository-wide tests-to-runtime-lines ratio is still far below three-to-one
- Shared reading workflow still has room for more whitespace-only and prompt-shape coverage
- Plain chat reading commands still do not have dedicated source-buffer key bindings
