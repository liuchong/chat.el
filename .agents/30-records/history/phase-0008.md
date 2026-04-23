# Phase 0008

- Type: progress
- Attention: records
- Status: completed
- Scope: approval-discoverability
- Tags: phase, approval, discoverability, emacs

## Goal

Make approval shortcuts discoverable through native Emacs prompts and immediate status feedback without abandoning the existing synchronous approval model.

## Completed

- Added shortcut hints directly into approval prompts
- Added a shared pending approval hint formatter
- Added first-occurrence pending approval announcements in chat mode and code mode
- Kept the request panel, prompt, and minibuffer guidance aligned
- Added regression coverage for prompt hints and native approval hint generation

## Tests

- Ran `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- Result: `196` tests run, `194` passed, `2` skipped, `0` failed

## Remaining

- Decide whether the next native Emacs step should be stronger header-line visibility for pending approvals
- Continue improving approval affordances without falling into transcript noise or custom widget complexity

## Risks

- More minibuffer feedback can still be missed if the user is not watching the echo area
- Chat mode and code mode still duplicate some UI-specific notification state

## Next Entry

Use the discoverability baseline to decide whether pending approvals need stronger native Emacs surface area.
