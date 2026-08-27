# Map

- Type: progress
- Attention: entry
- Status: active
- Scope: repository
- Tags: map, modules, routing

## Runtime

- `chat.el` is the root entry point
- `lisp/core/` contains sessions, tasks, approvals, files, context, streaming, diagnostics
- `lisp/llm/` contains provider abstraction and provider adapters
- `lisp/tools/` contains tool calling, shell safety, tool forging
- `lisp/ui/` contains chat UI flow and native task projections
- `lisp/code/` contains code mode, preview, intel, git helpers, refactor helpers

## Verification

- `tests/run-tests.el` is the canonical batch test entrypoint
- `tests/unit/` holds the main regression suite
- `tests/spike/` is for feasibility probes

## Human Docs

- `README.md` is the main human entry
- `docs/README.md` indexes human-facing docs
- `docs/troubleshooting-pitfalls.md` is the durable pitfall handbook
