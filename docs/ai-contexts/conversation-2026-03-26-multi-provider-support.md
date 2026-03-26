# Multi Provider Support

## Requirements

Add support for OpenAI, DeepSeek, Qwen, Grok, Claude, Gemini, and other mainstream domestic and international models.
Keep `kimi` as the default model.
Allow users to enable or disable providers through configuration.
Allow keys to live in chat specific config files instead of `init.el`.

## Technical Decisions

Kept the existing `model-id == provider symbol` session format to avoid breaking saved sessions.
Extended `chat-llm.el` with provider enable filtering, provider specific auth headers, and provider specific request URL logic.
Loaded config files in fixed order: `~/.chat.el`, `~/.chat/config.el`, then project local `chat-config.local.el`.
Used OpenAI compatible helpers for providers that follow the `/chat/completions` contract.
Added separate native adapters for Claude Messages API and Gemini generateContent API.

## Completed Work

Changed `chat-default-model` to `kimi`.
Added `chat-load-config-files` and multi location config loading in `chat.el`.
Added provider filtering through `chat-llm-enabled-providers`.
Added official provider entries for `deepseek`, `qwen`, `grok`, `mistral`, `glm`, `doubao`, `hunyuan`, `minimax`, `claude`, and `gemini`.
Refactored `openai` and `kimi` onto the shared OpenAI compatible path.
Updated streaming transport to reuse generic header and URL construction.
Added regression tests for config loading, provider filtering, native provider request building, and provider registration.
Updated `README.md`, `chat-config.local.el.example`, `docs/troubleshooting-pitfalls.md`, and `docs/PROJECT_STATUS.md`.

## Pending Work

Real network verification for each external provider is still recommended with user supplied keys.
Some provider default remote model names may need future adjustments as vendor catalogs change.

## Key Code Paths

`chat.el`
`lisp/llm/chat-llm.el`
`lisp/llm/chat-llm-compatible-providers.el`
`lisp/llm/chat-llm-claude.el`
`lisp/llm/chat-llm-gemini.el`
`lisp/core/chat-stream.el`
`tests/unit/test-chat-llm-providers.el`

## Verification

Ran `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`.
Result: 167 tests discovered, 165 passed, 2 skipped provider integration tests, 0 unexpected failures.

## Issues Encountered

The first config loading test accidentally used lexical locals, so loaded config values appeared missing until the test was changed to assert global bindings.
Changing the default model from `gpt-4o` to `kimi` changed code mode output budget expectations, so the streaming regression test was updated to derive the expected budget from provider configuration.
Added one new troubleshooting entry in this session for config file override order.
