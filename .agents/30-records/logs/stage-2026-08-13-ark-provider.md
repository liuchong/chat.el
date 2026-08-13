# Stage Log 2026-08-13 Volcengine Ark Provider

- Type: logs
- Attention: records
- Status: final
- Scope: project
- Tags: stage, providers, ark, volcengine

## Summary

Volcengine Ark Coding Plan is onboarded through both protocol
factories, proving the two-adapter architecture end to end with a
real vendor and a real key. Suite: 499 tests, 499 passing.

## What Landed

- New `lisp/llm/chat-llm-ark.el`:
  - `ark-code` via the OpenAI compatible factory
    (`https://ark.cn-beijing.volces.com/api/plan/v3`)
  - `ark-code-anthropic` via the Anthropic compatible factory
    (`https://ark.cn-beijing.volces.com/api/plan`)
  - key resolution: `chat-llm-ark-api-key`, optional key fn,
    auth-source fallback
- chat.el loads the new provider file.
- The user's Spacemacs init gained the Ark key with a note on
  switching the default model.

## Verification

- Live end to end through chat.el: `ark-code` answered "pong"
  (finish_reason stop), `ark-code-anthropic` answered "pong"
  (stop_reason end_turn), both against the real Ark endpoints.
- The backend behind `ark-code-latest` currently routes to a
  reasoning model (deepseek-v4-flash-ga) that emits thinking
  content; both parsers skip thinking blocks and extract the answer
  text correctly.
- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
  reports 499 results as expected, 0 unexpected.
