# Log Item

- Type: logs
- Attention: records
- Status: completed
- Scope: reading-workflow-slice2
- Tags: reading, defun, near-point, code-mode, capture

## Summary

Extended the in-Emacs reading workflow from region-only capture to a unified capture model that now supports region, defun, and near-point code questions in code mode.

### Technical Decisions

- Reused one normalized reading capture structure instead of adding separate prompt builders for each command
- Kept the new capture commands on the existing code-mode path rather than branching into plain chat mode
- Preserved the existing region key bindings and added the new defun and near-point entry points as command-level workflow primitives first
- Fixed defun line reporting at the capture layer instead of patching tests or formatting output later

### Completed Work

- Added `chat-code-quote-defun`
- Added `chat-code-ask-defun`
- Added `chat-code-quote-near-point`
- Added `chat-code-ask-near-point`
- Refactored reading prompts to use a shared capture model across region, defun, and near-point
- Updated README, code mode cheatsheet, usage guide, and project status

### Verification

- Ran targeted tests for region, defun, and near-point quoting and ask flows
- Ran `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- Expected baseline after this stage: `214` regression tests run, `214` passed, `0` skipped, `0` failed

### Remaining

- The reading workflow still does not expose current-file capture
- Plain chat mode still does not provide matching reading capture commands
- The new defun and near-point commands are currently discoverable through docs and `M-x`, but not yet through dedicated code-mode key bindings
