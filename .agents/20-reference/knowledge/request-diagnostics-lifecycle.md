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

## Regression Guard

- Test diagnostics snapshots, stream chunk counting, request-id propagation, and status commands
- Avoid asserting brittle event order when mocked async callbacks can complete immediately
