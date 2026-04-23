# Project Status

Last updated: 2026-04-23

## Summary

`chat.el` is now at a usable coding assistant baseline inside Emacs.
The core chat flow, tool calling flow, file tools, approval gates, async request path, context trimming, and tool forging path are all implemented and covered by tests.
`code-mode` now has a repaired basic chat flow with preview backed edits, but several advanced helper modules remain experimental.
Runtime source files now live under `lisp/core`, `lisp/llm`, `lisp/tools`, `lisp/ui`, and `lisp/code`, with `chat.el` kept at the repository root as the single entry point.
The provider layer now supports mainstream official models across domestic and international vendors, with `kimi` kept as the default and local config files loaded from user and project locations.
The repository now uses `.agents/` as the formal agent knowledge base, with legacy workflow logs migrated out of `docs/ai-contexts/`.

## Implemented Areas

### Chat Core

- session creation and persistence
- raw request and response inspection
- async non streaming request path
- optional streaming UI path
- response cancellation

### LLM Providers

- official OpenAI, Kimi, Claude, Gemini, DeepSeek, Qwen, Grok, Mistral, GLM, Doubao, Hunyuan, and MiniMax provider entries
- provider specific auth headers and request URLs
- provider enable and disable list via configuration
- config loading from `~/.chat.el`, `~/.chat/config.el`, and project `chat-config.local.el`

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
- 198 tests discovered
- 196 passing
- 2 skipped provider integration tests
- 0 known failures in the current baseline

### Stability Highlights

- no thread based request deadlocks in the main request path
- async requests now have timeout timers and cleanup
- empty assistant messages are filtered before API submission
- risky tools require approval before execution
- AI generated tools require approval before registration
- shell execution no longer goes through shell expansion
- code mode supports stable input, multi turn requests, cancel, preview creation, and explicit `code-edit` parsing
- code mode now reuses the shared JSON tool calling contract and follow up tool loop
- code mode follow up rendering now returns to the UI buffer before touching markers
- debug logs stay in `~/.chat/chat.log` unless minibuffer echo is explicitly enabled
- inline JSON tool calls are stripped from displayed assistant text before rendering
- code mode now shows a safety limit notice instead of raw tool JSON when automatic tool follow up stops
- code mode tool execution now inherits the active project root for file access and shell working directory
- builtin readonly shell whitelist now covers common inspection commands and safe `cd DIR && CMD` exploration
- code mode now shows explicit running, success, failed, cancelled, and stopped status in the buffer header line
- code mode prompt now includes project rooted operational guardrails to reduce aimless tool retries
- code mode now injects project `AGENTS.md` into context when present
- code mode now sends hard coded non-negotiable engineering rules in every programming request
- request diagnostics now expose current phase, recent events, and stalled-request hints in both chat and code mode
- request execution state now has a dedicated request panel so tool steps no longer clutter assistant transcript output
- request panel now includes approval choices, command-level approval context, and shell whitelist mutations
- approval prompts now support direct shortcut decisions that match the request panel action hints
- approval shortcut guidance now also appears in native prompt text and first-occurrence minibuffer feedback in chat mode and code mode
- pending approvals now remain visible in persistent native status surfaces instead of only transient prompts
- `.agents/` now holds the formal agent workflow records, phase history, reference decisions, and imported legacy logs

## Known Boundaries

- token counting is still heuristic rather than model exact
- streaming currently falls back to the async request path in `chat-llm-stream`
- default providers still depend on external API availability and local keys
- some provider default remote model names are best effort defaults and may need local adjustment as vendor catalogs change
- provider integration tests are intentionally skipped in offline or unconfigured environments
- code mode refactor, git helper, indexing extras, and performance helpers should still be treated as experimental

## Recommended Next Work

- make true provider streaming and fallback behavior share one transport abstraction
- improve session editing and regeneration flows
- add integration coverage for approval and tool loop behavior
- consider a richer session browser and export flow

## Key Files

| File | Area |
|------|------|
| `chat.el` | entry point |
| `lisp/ui/chat-ui.el` | UI and response lifecycle |
| `lisp/core/chat-session.el` | persistence |
| `lisp/llm/chat-llm.el` | provider abstraction |
| `lisp/core/chat-stream.el` | stream parsing |
| `lisp/tools/chat-tool-caller.el` | tool protocol |
| `lisp/core/chat-approval.el` | approvals |
| `lisp/core/chat-files.el` | file tools |
| `lisp/core/chat-context.el` | context trimming |
| `lisp/tools/chat-tool-forge.el` | tool registry and compilation |
| `lisp/tools/chat-tool-forge-ai.el` | AI tool generation |
