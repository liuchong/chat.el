# Log Item

- Type: logs
- Attention: records
- Status: completed
- Scope: whitespace-capture-guardrails
- Tags: tests, reading, whitespace, guardrails, correctness

## Summary

Expanded regression coverage around whitespace-only reading captures and fixed the shared helper layer so region, `near-point`, and `current-file` all reject context that contains only whitespace.

### Technical Decisions

- Kept the stage focused on shared helper correctness instead of adding more surface commands
- Treated whitespace-only captures as invalid input because they produce useless prompts even when they are technically non-empty strings
- Centralized the fix in the shared non-empty-code validation path so multiple capture types inherit the same guardrail

### Completed Work

- Added regression tests for whitespace-only region rejection
- Added regression tests for whitespace-only `near-point` capture rejection
- Added regression tests for whitespace-only `current-file` capture rejection
- Tightened shared helper validation to trim whitespace before accepting code content
- Updated README, project status, and `.agents` records

### Verification

- Ran `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- Expected baseline after this stage: `275` regression tests run, `275` passed, `0` skipped, `0` failed

### Remaining

- The repository-wide tests-to-runtime-lines ratio is still far below three-to-one
- Shared reading workflow still has room for more prompt-shape and cross-buffer coverage
- Plain chat reading commands still do not have dedicated source-buffer key bindings
