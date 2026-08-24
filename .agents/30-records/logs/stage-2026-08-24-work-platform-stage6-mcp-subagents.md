# Stage Log: Work Platform Stage 6 MCP And Sub-agents

- Type: stage-log
- Status: complete
- Scope: work-platform
- Date: 2026-08-24

## Summary

Stage 6 adds optional MCP and sub-agent backend primitives. `chat-mcp.el`
implements JSON-RPC stdio and HTTP request handling with request ids,
line buffering, cancellation notification, reconnect, and teardown.
`chat-subagent.el` adds in-process child-session isolation and an
external subprocess-agent backend with captured output and cancellation.

## Changes

- Added MCP JSON-RPC request, notification, line decoding, and response
  matching by id.
- Added stdio process lifecycle, reconnect, cancel notification, and
  stop handling.
- Added HTTP JSON-RPC POST request primitive.
- Added in-process sub-agent records with child sessions, depth caps,
  budget metadata, and parent-safe summaries.
- Added external subprocess-agent records with log capture and
  cancellation.
- Added a tiny fake MCP server fixture under `tests/spike/`.

## Verification

- Focused Stage 6 tests:
  `emacs -Q -batch -l tests/run-tests.el --eval '(ert-run-tests-batch "chat-\\(mcp\\|subagent\\)")'`
- Canonical suite:
  `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`

## Remaining Work

- Ship programming, office, and daily capability packs.
- Add session profiles so surfaces expose relevant scoped tools instead
  of the full global catalog.
- Surface child/background/MCP lifecycle in request panels.
