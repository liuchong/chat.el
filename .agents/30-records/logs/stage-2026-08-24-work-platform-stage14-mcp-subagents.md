# Stage Log: Work Platform Stage 14 MCP And Sub-agents

- Type: logs
- Attention: records
- Status: complete
- Scope: MCP, nested agents, subprocess agents
- Tags: json-rpc, stdio, http, sse, isolation, jsonl

## Summary

This stage promotes external capability transports and sub-agents from
standalone primitives to first-class tools in the primary agent loop.

## Changes

- Load configured MCP definitions without connecting at startup.
- Initialize stdio or Streamable HTTP servers only on explicit connect.
- Support asynchronous request callbacks, timeout, cancellation, and
  pending-request cleanup.
- Decode Streamable HTTP JSON and SSE responses and preserve session ids.
- Discover remote tool schemas and register namespaced forged tools.
- Map remote read-only/destructive annotations to shared effect metadata.
- Register generic list/connect/call tools for configured servers.
- Run nested sub-agents through the shared kernel with isolated durable
  child sessions, copied tool overlays, depth limits, and step budgets.
- Return only parent-safe final summaries from nested runs.
- Define one-request JSONL stdin and captured JSONL output for external
  subprocess agents.
- Register run/list/status/cancel/output tools with shared approval and
  request lifecycle behavior.

## Verification

- Focused protocol/runtime suite:
  `Ran 12 tests, 12 results as expected, 0 unexpected`
- Canonical command:
  `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- Result:
  `Ran 585 tests, 585 results as expected, 0 unexpected`

## Remaining Work

- Complete capability-pack tools for programming, office, and daily use.
- Add optional live-server integration tests per deployed MCP service.
