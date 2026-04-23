# Imported Log

- Type: logs
- Attention: records
- Status: imported
- Scope: legacy-session
- Tags: imported, legacy, ai-context

## Original Record

# Code Mode Repair

## Requirements

Repair `code-mode` so the user can type and submit prompts normally.
Stabilize the request flow for both async and streaming responses.
Review and repair the `code-mode` related modules, tests, specs, and user facing docs.
Add regression coverage for the broken interaction path and repaired peripheral modules.

## Technical Decisions

Reworked `chat-code.el` to use stable message and input markers instead of rebuilding the prompt after every turn.
Aligned code mode streaming with the real `chat-stream-request` contract and process sentinel finalization.
Stopped storing live `chat-code-session` structs inside `chat-session` metadata because that created circular data during auto save.
Standardized on `chat-edit` as the only real edit model and removed new work from the orphan `chat-code-edit` path.
Downgraded high risk peripheral modules to experimental status in docs unless the current implementation was repaired and covered by tests.

## Completed Work

Updated `chat-code.el` to keep a persistent input area, append conversation output before the prompt, block duplicate sends while a response is active, and support cancellation.
Fixed code mode to persist user and assistant messages into the base session so follow up turns work.
Fixed the streaming path to use the current core stream API and finish responses through a sentinel.
Fixed `chat-code.el` explicit fenced `code-edit` parsing so multiline JSON payloads now produce real `chat-edit` structs.
Hooked preview creation back into the main code mode workflow and made `chat-code-view-preview` materialize the preview buffer from the pending edit.
Fixed `chat-code-preview.el` to use `chat-edit` accessors and fall back to an internal diff when the `diff` executable is unavailable.
Repaired `chat-code-refactor.el` so rename now produces whole file rewrite edits, extract no longer references the `code-totract` typo, and refactor preview applies a flattened edit list.
Repaired `chat-code-intel.el` persistence so saved indexes now round trip symbols, references, and call graph data instead of always returning `nil`.
Repaired `chat-code-git.el` argument normalization and async callback ordering, and removed the auto commit follow up from AI suggested commit messages.
Repaired `chat-code-perf.el` incremental update fallback and replaced the broken dummy background subprocess startup with an idle timer queue.
Updated `specs/002-code-mode.md`, summary, quickstart, phase notes, `docs/code-mode-usage.md`, `docs/code-mode-cheatsheet.md`, and `README.md` so they describe current reality instead of historical or fictional completion state.
Added `tests/unit/test-chat-code.el` and `tests/unit/test-chat-code-modules.el` coverage for buffer setup, send flow, streaming API usage, explicit edit parsing, preview creation, intel persistence, git argv normalization, refactor rewrite generation, and perf fallback behavior.
Updated `docs/troubleshooting-pitfalls.md` with the multiline fenced block parsing and persistence stub pitfalls.

## Pending Work

Manual interactive verification inside a real Emacs window is still recommended.
There is still one unrelated failing test in `tests/unit/test-chat-tool-caller.el`.
Advanced modules like multi file refactor, git review, and background indexing should still be treated as experimental until they receive broader interactive verification.

## Key Code Paths

`chat-code.el`
`chat-code-preview.el`
`chat-code-refactor.el`
`chat-code-intel.el`
`chat-code-git.el`
`chat-code-perf.el`
`tests/unit/test-chat-code.el`
`tests/unit/test-chat-code-modules.el`
`docs/troubleshooting-pitfalls.md`

## Verification

Ran `emacs -Q -batch -l tests/run-tests.el`.
All repaired `code-mode` tests passed.
The full suite still has one unrelated failure: `chat-tool-caller-denies-unapproved-dangerous-tool`.

## Issues Encountered

`chat-code-session-create` stored a live `chat-code-session` inside `chat-session-metadata`, which broke JSON auto save once code mode started persisting chat history.
Emacs fenced block parsing needed an explicit multiline regex because `.` does not cross newlines.
`chat-code-intel-save-index` existed while `chat-code-intel-load-index` still returned `nil`, which made higher level perf features look implemented while silently rebuilding state.
Added troubleshooting entries in this session.
