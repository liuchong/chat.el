# Knowledge Item

- Type: knowledge
- Attention: reference
- Status: active
- Scope: tests
- Tags: batch, tests, state, isolation

## Problem

Batch test runs can inherit invalid `HOME` or `default-directory` state and break persistence or external process execution.

## Symptoms

- Session tests attempt to write into the user home directory
- `diff` or `process-file` calls fail because they inherit a stale working directory

## Resolution

- Use `tests/run-tests.el` as the canonical test entrypoint
- Create isolated state directories for sessions, tools, backups, indexes, and logs in the test runner
- Bind process execution to a known existing directory instead of trusting ambient state

## Regression Guard

- Keep `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit` green
- Add regressions when a test failure is caused by inherited filesystem state
