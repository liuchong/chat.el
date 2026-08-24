# Stage Log: Work Platform Stage 15 Capability Packs

- Type: logs
- Attention: records
- Status: complete
- Scope: programming, office, daily capabilities
- Tags: capf, web, org, dired, calc, message

## Summary

This stage completes the concrete Emacs-first tools required for
programming, office work, and simple daily tasks.

## Changes

- Run native completion-at-point sources at an allowed file position.
- Retrieve HTTP(S) pages and render readable bounded text with Emacs.
- Keep web retrieval and MCP initialize/discovery chains asynchronous and
  cancellable.
- Aggregate Org TODO, scheduled, and deadline entries from allowed files.
- Capture Org headings and update exact TODO/schedule targets.
- Open and copy files/directories alongside existing list/mkdir/rename.
- Convert unit-bearing values with the native Calc unit engine.
- Create unsent message-mode draft buffers backed by local draft records.
- Add the tools to code, office, and daily profile overlays.
- Verify profile filtering at provider schema generation, not only at
  execution.
- Keep correspondence draft-only and route personal, network, write, and
  outbound capabilities through shared approval metadata.

## Verification

- Focused capability suite:
  `Ran 9 tests, 9 results as expected, 0 unexpected`
- Canonical command:
  `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- Result:
  `Ran 591 tests, 591 results as expected, 0 unexpected`
- Cross-module integration:
  `Ran 3 tests, 1 results as expected, 0 unexpected, 2 skipped`
  (online checks skipped without credentials)
- Deterministic end-to-end:
  `Ran 2 tests, 2 results as expected, 0 unexpected`

## Remaining Work

- Optional real-provider and live MCP integration checks remain
  environment-dependent and are not part of the deterministic suite.
