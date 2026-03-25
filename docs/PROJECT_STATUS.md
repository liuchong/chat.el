# Project Status

Last updated: 2026-03-25

## Summary

`chat.el` is now at a usable coding assistant baseline inside Emacs.
The core chat flow, tool calling flow, file tools, approval gates, async request path, context trimming, and tool forging path are all implemented and covered by tests.

## Implemented Areas

### Chat Core

- session creation and persistence
- raw request and response inspection
- async non streaming request path
- optional streaming UI path
- response cancellation

### Tool Calling

- one tool per turn JSON contract
- built in file tools registration
- approval for risky tool execution
- bounded follow up tool loop
- tool results fed back into later model turns

### File Operations

- read and line range reads
- directory listing and grep
- write replace and patch flows
- diff previews for patch operations
- symlink aware path safety checks

### Context Management

- token estimation
- leading system message preservation
- omitted history summary messages
- summary inclusion of tool calls and tool results

### Tool Forging

- AI assisted tool generation
- explicit approval before tool registration
- lambda only elisp source validation
- registry loading and persistence

## Current Quality Baseline

### Test Status

- canonical command: `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- 122 tests discovered
- 120 passing
- 2 skipped provider integration tests
- 0 failures in the current baseline

### Stability Highlights

- no thread based request deadlocks in the main request path
- async requests now have timeout timers and cleanup
- empty assistant messages are filtered before API submission
- risky tools require approval before execution
- AI generated tools require approval before registration
- shell execution no longer goes through shell expansion

## Known Boundaries

- token counting is still heuristic rather than model exact
- streaming currently falls back to the async request path in `chat-llm-stream`
- default providers still depend on external API availability and local keys
- provider integration tests are intentionally skipped in offline or unconfigured environments

## Recommended Next Work

- make true provider streaming and fallback behavior share one transport abstraction
- improve session editing and regeneration flows
- add integration coverage for approval and tool loop behavior
- consider a richer session browser and export flow

## Key Files

| File | Area |
|------|------|
| `chat.el` | entry point |
| `chat-ui.el` | UI and response lifecycle |
| `chat-session.el` | persistence |
| `chat-llm.el` | provider abstraction |
| `chat-stream.el` | stream parsing |
| `chat-tool-caller.el` | tool protocol |
| `chat-approval.el` | approvals |
| `chat-files.el` | file tools |
| `chat-context.el` | context trimming |
| `chat-tool-forge.el` | tool registry and compilation |
| `chat-tool-forge-ai.el` | AI tool generation |
