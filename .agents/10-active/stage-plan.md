# Stage Plan

- Type: progress
- Attention: active
- Status: active
- Scope: agent-runtime
- Tags: stage, plan, termini, bridge, integration

## Goal

Deliver M8: a versioned `termini.el` bridge between the local Agent Runtime and
the Termini platform without making either side depend on the other's UI or
process internals.

## Completed

- M0-M6 lifecycle, capability, extension, task, content and recovery contracts
- M7 attributable memory, derived Trace reconstruction and deterministic evals
- native Memory, Trace and evaluation inspection views
- canonical verification at 1511/1511

## Next Steps

1. Inspect the Termini repository and freeze the bridge boundary before adding
   transport code to `chat.el`.
2. Define versioned request, progress, cancellation, artifact and completion
   envelopes with stable session, Turn, task and parent correlation.
3. Add capability negotiation and deterministic handling for unsupported or
   newer bridge contracts.
4. Implement local bridge state independently of Emacs buffers and provider
   request objects.
5. Add idempotent reconnect and duplicate-delivery handling, including terminal
   completion and cancellation races.
6. Expose concise native dispatch, status, detail, cancel and reconnect commands
   in `termini.el`.
7. Build offline adapter fixtures first, then isolate opt-in live integration,
   stress and security checks from the canonical suite.

## Risks

- A bridge can accidentally become a second task database instead of an
  adapter over runtime-owned state.
- Retries can duplicate remote work unless request identity and terminal
  idempotence are explicit before transport implementation.
- Reconnect can confuse stale progress with current state if revisions and
  ordering are absent.
- Artifact transfer must remain bounded and referenced rather than embedding
  large or sensitive payloads in lifecycle records.

## Next Entry

Record the M8 Termini bridge decision and acceptance spec before implementation
begins.
