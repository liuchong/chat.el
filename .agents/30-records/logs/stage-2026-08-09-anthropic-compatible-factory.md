# Stage Log 2026-08-09 Anthropic Compatible Provider Factory

- Type: logs
- Attention: records
- Status: final
- Scope: project
- Tags: stage, providers, anthropic, compatibility

## Summary

Both protocol families are now generic adapters, so most vendors can
be added with a base URL, a key function, and a model name. Suite:
498 tests, 498 passing.

## What Landed

- `chat-llm-register-anthropic-compatible-provider`: a factory
  mirroring the OpenAI compatible one, registering the Anthropic
  Messages API shape (x-api-key + anthropic-version headers, system
  prompt hoisting, content block parsing, delta streaming). The
  request path defaults to `/v1/messages` and can be overridden.
- `claude` now registers through the factory with unchanged
  behavior.
- New `kimi-code-anthropic` provider: the Kimi Code Anthropic
  endpoint at `https://api.kimi.com/coding`, reusing the kimi-code
  key chain and curl transport.
- `chat-llm--extract-finish-reason` also reads Anthropic style
  `stop_reason` and normalizes `max_tokens` to `"length"`, so the
  kernel truncation refusal now covers anthropic format providers.

## Verification

- Spike: `https://api.kimi.com/coding/v1/messages` answers 401 (not
  404) with the expired local key, proving the endpoint path.
- Live probe through `kimi-code-anthropic` returns the Anthropic
  format error body correctly through the async transport.
- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
  reports 498 results as expected, 0 unexpected.

## Not Done

- The expired kimi-code key itself must be renewed by the user;
  both protocol paths are proven against the live endpoint.
