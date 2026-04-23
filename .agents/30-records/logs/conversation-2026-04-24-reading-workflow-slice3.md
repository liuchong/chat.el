# Log Item

- Type: logs
- Attention: records
- Status: completed
- Scope: reading-workflow-slice3
- Tags: reading, current-file, shared-capture, tests, code-mode

## Summary

Moved reading capture into a shared `chat-reading` module, completed the code-mode side with bounded current-file capture, and added a denser set of unit tests around reading capture behavior.

### Technical Decisions

- Extracted reading capture and prompt formatting into `lisp/core/chat-reading.el` so code mode and future chat mode work can share the same semantics
- Added a bounded current-file capture instead of an unbounded whole-file dump to keep the workflow explicit and controllable
- Guarded defun capture to programming buffers so plain text no longer produces fake defun captures
- Increased coverage at the shared-module level instead of only adding more command-surface tests

### Completed Work

- Added `chat-reading-capture-region`
- Added `chat-reading-capture-defun`
- Added `chat-reading-capture-near-point`
- Added `chat-reading-capture-current-file`
- Added `chat-reading-format-question`
- Added `chat-code-quote-current-file`
- Added `chat-code-ask-current-file`
- Refactored `chat-code.el` to use the shared reading capture module
- Added new unit coverage in `test-chat-reading.el` and extended `test-chat-code.el`

### Verification

- Ran targeted reading workflow and code-mode capture tests during implementation
- Ran `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- Expected baseline after this stage: `227` regression tests run, `227` passed, `0` skipped, `0` failed

### Remaining

- Plain chat mode still lacks first-class reading capture entry points
- The repository-wide tests-to-runtime-lines ratio is still far below three-to-one
- Current-file capture is bounded by line count and still intentionally refuses oversized files
