# Stage Plan

- Type: progress
- Attention: reference
- Status: complete
- Scope: agent-runtime
- Tags: stage, plan, termini, bridge, integration

## Goal

Deliver M8: a versioned `termini.el` bridge between the local Agent Runtime and
the Termini platform without making either side depend on the other's UI or
process internals.

## Completed

- M0-M6 lifecycle, capability, extension, task, content and recovery contracts
- M7 attributable memory, derived Trace reconstruction and deterministic evals
- M8 versioned App Server bridge and optional `termini.el` entry point
- native RuntimeSession, job, tail, cancellation and attachment controls
- deterministic offline protocol fixtures and foreground live handshake
- canonical verification at 1539/1539

## Execution Record

1. Inspected the App Server protocol and fixed the runtime ownership boundary.
2. Added Decision 0026 and Spec 020 before transport implementation.
3. Implemented bounded JSONL framing, correlation, capabilities and reconnect.
4. Added RuntimeSession, message, job, tail and attachment projections.
5. Added explicit local session binding without mirroring remote tasks.
6. Added the optional root entry point and native session/job views.
7. Ran deterministic fixtures, a foreground live handshake and the canonical
   suite.

## Risks

- A bridge can accidentally become a second task database instead of an
  adapter over runtime-owned state.
- Retries can duplicate remote work unless request identity and terminal
  idempotence are explicit before transport implementation.
- Reconnect can confuse stale progress with current state if revisions and
  ordering are absent.
- Artifact transfer must remain bounded and referenced rather than embedding
  large or sensitive payloads in lifecycle records.

## Result

The M0-M8 Agent Runtime roadmap is complete. Future transport or product work
must preserve Decision 0026's single-owner state rule and extend the negotiated
bridge rather than reading Termini persistence directly.
