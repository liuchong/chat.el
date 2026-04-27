# Code Mode Help Surface

- Type: log
- Attention: record
- Status: complete
- Scope: discoverability
- Tags: code-mode, help, reading, shortcuts

## Summary

Added a native code-mode help surface so command discovery no longer depends only on README and external docs.

## Changes

- added `chat-code-show-help`
- bound `C-c C-h` in `chat-code-mode`
- documented reading commands, session commands, preview flow, and request-panel usage in the native help text
- updated regression coverage and README command listings

## Verification

- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`

## Remaining

- decide later whether plain chat and code mode should share one generated help source or keep separate native help buffers
