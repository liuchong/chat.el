# Knowledge Item

- Type: knowledge
- Attention: reference
- Status: active
- Scope: diagnostics
- Tags: diagnostics, async, streaming, lifecycle

## Problem

Users need actionable visibility when a request appears to stall, but transport state is naturally split across async request code, stream code, and UI layers.

## Symptoms

- The UI stays on `Getting response from AI...`
- Users cannot tell whether the request is waiting on the provider, stalled in streaming, or blocked in a tool follow-up

## Resolution

- Keep request traces in `chat-request-diagnostics.el`
- Record lifecycle events from `chat-llm.el` and `chat-stream.el`
- Let `chat-ui.el` and `chat-code.el` own current request ids, stalled hints, and status commands
- Carry approval context through tool events so the request panel can show pending choices, command-specific approvals, and whitelist mutations in one execution surface
- Keep approval execution synchronous, but expose fast approval commands and minibuffer bindings so the request panel and the actual decision path stay aligned
- Prefer native prompt and minibuffer messaging to teach approval shortcuts instead of inserting extra transcript content or building a custom widget layer
- Use persistent native status surfaces such as `header-line`, mode line, and lightweight status headers when pending approvals should remain visible beyond a one-shot echo-area message
- Treat persistent status surfaces as a scarce channel: only blocking states that change the user's next action belong there; transient thinking and ordinary tool execution stay in echo-area hints or the request panel

## Regression Guard

- Test diagnostics snapshots, stream chunk counting, request-id propagation, and status commands
- Avoid asserting brittle event order when mocked async callbacks can complete immediately
