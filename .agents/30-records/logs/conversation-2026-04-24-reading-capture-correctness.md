# Log Item

- Type: logs
- Attention: records
- Status: completed
- Scope: reading-capture-correctness
- Tags: tests, reading, region, reuse, correctness

## Summary

Expanded helper-level regression coverage around reading capture correctness and reused plain-chat session input replacement, and fixed a real off-by-one bug in region capture line metadata.

### Technical Decisions

- Kept this stage focused on helper-level correctness instead of adding more user-facing commands
- Treated the region end-line mismatch as a real metadata bug and fixed the shared helper rather than relaxing the new test
- Added plain chat reused-session tests to ensure quoting and asking replace stale input before reuse

### Completed Work

- Fixed `chat-reading-capture-region` metadata when a region ends at the next line boundary
- Added a regression test for the line-boundary region case
- Added plain chat tests ensuring reused sessions replace stale input before quote and ask flows
- Updated README, project status, and `.agents` records

### Verification

- Ran `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- Expected baseline after this stage: `268` regression tests run, `268` passed, `0` skipped, `0` failed

### Remaining

- The repository-wide tests-to-runtime-lines ratio is still far below three-to-one
- Shared reading workflow still has room for more prompt-shape and cross-buffer coverage
- Plain chat reading commands still do not have dedicated source-buffer key bindings
