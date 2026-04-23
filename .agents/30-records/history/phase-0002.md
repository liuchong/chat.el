# Phase 0002

- Type: progress
- Attention: records
- Status: completed
- Scope: tool-and-async-foundation
- Tags: phase, tools, async, approval

## Goal

Move `chat.el` from basic chat into a safer tool-capable async assistant.

## Completed

- Added tool calling and tool forging flows
- Added streaming support and later repaired the async non-streaming path
- Introduced approvals, shell whitelist behavior, and openclaw-style staged hardening
- Improved workflow rules in `AGENTS.md`

## Tests

- Expanded `chat-llm`, `chat-stream`, `chat-tool-caller`, `chat-approval`, and `chat-ui` unit coverage

## Remaining

- stronger code mode
- better prompt discipline
- clearer long-term repository structure

## Risks

- Tool protocol and UI presentation drifted quickly during rapid iteration

## Next Entry

Reorganize the repository and harden code mode for real coding workflows.
