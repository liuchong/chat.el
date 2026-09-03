# In-Process Streaming Transport and Link Resilience

- Type: stage-record
- Attention: active
- Status: implementation-verified
- Scope: model streaming transport, retry and endpoint health
- Date: 2026-09-03
- Spec: specs/037-in-process-streaming-transport-and-link-resilience.md

## Trigger

A five-hour session on a relay (xgapi/deepseek-v4-pro-0813) died with
`[Live] exited abnormally with code 18` -- curl's CURLE_PARTIAL_FILE: the
relay cut the SSE stream mid-flight.  The turn had already streamed partial
content, so the no-payload retry contract refused to retry, and the user got
a bare curl exit code with no cause and no next step.

## What Changed

1. `chat-stream-request` no longer forks curl.  The new
   `lisp/core/chat-stream-net.el` owns streaming in-process: GnuTLS via
   `open-network-stream` with `:nowait`, HTTP/1.1 `Connection: close`,
   incremental chunked decoding, and line-aligned delivery (a UTF-8
   sequence can no longer be split across a decoding boundary).  No
   temporary credential files.  Terminal state is the structured
   `chat-stream-terminal` process property; `chat-model-runtime` reads it
   instead of matching process event strings.  The kimi-code non-stream
   curl path (`:async-transport`) is a different contract and unchanged.
2. Failures are classified at the transport: dns, connect, tls, http,
   mid-stream-close, stall.  Messages say what happened, the likely cause
   and the next step, instead of a curl exit code.  A stall watchdog
   (`chat-stream-stall-timeout`, default 120s) terminates silent streams.
3. A turn cut mid-stream after partial content is re-sent from scratch, at
   most `chat-agent-model-stream-resume-retries` (default 2) times, via the
   existing `model-retry` event with `:resume t`.  Nothing partial is
   recorded; tools only run after a turn completes, so the only cost of a
   resume is its tokens.  No-payload retry (existing) is unchanged.
4. Endpoint health: consecutive transport-class failures cool an endpoint
   down (threshold 3, 60s doubling to 30m cap); a provider registered with
   `:base-urls` falls to the next line, and the earliest-expiring cooldown
   wins a half-open trial.  Success clears the record.  This never reorders
   models or rewrites registrations.

## Verification

- New `tests/unit/test-chat-stream-net.el`: an in-process TCP server covers
  a complete chunked stream, a mid-stream cut, an HTTP error body, a stall,
  multibyte delivery, cooldown/half-open/success-clear, and base-url
  failover ordering.  No external network.
- `test-chat-agent.el` gained resume and classification tests; the
  curl-era stream tests were rewritten against the new transport.
- Full suite: 2056 passed, 0 unexpected (2 pre-existing environment skips).
- Live smoke against api.xgapi.top: TLS + SSE through the new transport
  streamed a complete answer with terminal `(:status ok)`.
