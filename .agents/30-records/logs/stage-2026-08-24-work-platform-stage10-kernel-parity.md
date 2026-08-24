# Stage Log: Work Platform Stage 10 Kernel Parity

- Type: logs
- Attention: records
- Status: complete
- Scope: agent-kernel, streaming, scheduling
- Tags: stream, reasoning, tools, resources, cancellation

## Summary

This stage closes the remaining kernel gaps found by the execution audit:
provider stream normalization, resource-aware tool scheduling, and
cancellation propagation into active asynchronous tools.

## Changes

- Normalize native tool starts and partial JSON input across supported
  streaming response shapes.
- Normalize nested stop reasons before enforcing truncated-tool refusal.
- Emit typed reasoning deltas separately from user-visible text.
- Treat provider error events as terminal even after partial text.
- Add an asynchronous forged-tool contract with cancellable handles and
  optional resource-access declarations.
- Overlap only non-conflicting asynchronous reads while preserving
  provider result order.
- Serialize all write/destructive and approval-bearing calls.
- Propagate run cancellation into every active asynchronous tool handle
  and ignore late completion paths.
- Keep synchronous tools on the same scheduler path.

## Verification

- Canonical command:
  `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- Result:
  `Ran 569 tests, 569 results as expected, 0 unexpected`

## Remaining Work

- Persist plugin permission metadata and guarantee one chronological
  rollback stack across every owned resource type.
- Complete durable session branching and compaction behavior.
