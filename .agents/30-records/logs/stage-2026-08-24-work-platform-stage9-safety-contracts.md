# Stage Log: Work Platform Stage 9 Safety Contracts

- Type: logs
- Attention: records
- Status: complete
- Scope: tool-contracts, approvals, plugins
- Tags: schemas, privacy, approval, plugins, regression

## Summary

The execution audit found that provider schemas were not enforced at
runtime, permission metadata did not affect approval, and user plugin
registration happened after enabled plugins were started. This stage
closes those foundation and plugin safety gaps.

## Changes

- Validate required arguments, JSON primitive types, enumerations, and
  unknown fields before approval or execution.
- Treat JSON false as a present required boolean while normalizing it to
  nil for Lisp tool functions.
- Require approval from tool sensitivity, effects, and optional
  call-specific predicates in addition to the legacy tool-id policy.
- Require approval for opted-in buffer reads outside project/session
  scope while preserving hard denial for credential buffers.
- Load only explicitly enabled user plugin files and register them before
  starting enabled plugins.
- Retry pending plugin dependencies after setup provides a service.
- Remove investigation-source terminology from active runtime comments.

## Verification

- Canonical command:
  `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- Result:
  `Ran 564 tests, 564 results as expected, 0 unexpected`

## Remaining Work

- Complete the unified stream contract and resource-aware tool scheduler.
- Propagate cancellation into in-flight asynchronous tool work.
