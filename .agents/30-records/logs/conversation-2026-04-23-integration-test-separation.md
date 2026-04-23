# Log Item

- Type: logs
- Attention: records
- Status: completed
- Scope: integration-test-separation
- Tags: tests, integration, batch, kimi, runner

## Summary

Separated real Kimi provider checks from the canonical batch suite so the default regression runner is fully deterministic and no longer reports skipped online tests.

### Technical Decisions

- Kept `tests/run-tests.el` as the canonical regression runner for batch-safe tests only
- Moved real Kimi request tests out of `tests/unit/` and into a dedicated `tests/integration/` path
- Added `tests/run-integration-tests.el` as an explicit integration entrypoint for networked provider checks

### Completed Work

- Removed online Kimi request tests from `tests/unit/test-chat-llm-kimi.el`
- Added `tests/integration/test-chat-llm-kimi-integration.el`
- Added `tests/run-integration-tests.el`
- Updated README and project status docs to distinguish regression and integration commands

### Verification

- Ran `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- Result: `205` regression tests run, `205` passed, `0` skipped, `0` failed

### Remaining

- The new integration runner still requires real credentials and reachable provider endpoints
- Additional provider integration coverage has not yet been split out because only Kimi had been mixed into the canonical unit path
