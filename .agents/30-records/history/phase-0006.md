# Phase 0006

- Type: progress
- Attention: records
- Status: completed
- Scope: approval-panel
- Tags: phase, approval, whitelist, request-panel

## Goal

Make approval and whitelist decisions visible in the shared request panel so execution flow no longer splits between visible request state and opaque prompts.

## Completed

- Extended approval events with decision options and shell command context
- Added explicit whitelist update events for command-level allowlist changes
- Updated request panel rendering to show approval choices, command context, and whitelist mutations
- Preserved command context for whitelisted shell execution events in the tool-caller path
- Added regression coverage for approval observer payloads, panel rendering, and whitelisted shell event context

## Tests

- Ran `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- Result: `191` tests run, `189` passed, `2` skipped, `0` failed

## Remaining

- Decide whether approval input itself should stay minibuffer-based or move into a more explicit request-panel interaction model
- Continue tightening the panel into a more prominent execution timeline

## Risks

- Users can now see approval state clearly, but may still feel input friction because decisions remain Emacs-native prompts
- Approval and diagnostics state still meet in the panel through aggregated tool events rather than a single canonical UI model

## Next Entry

Use the richer approval-aware panel as the base for the next execution UX stage.
