# Stage: Termini App Server Bridge

- Type: logs
- Attention: records
- Status: complete
- Scope: agent-runtime
- Tags: termini, bridge, json-rpc, projections, native-ui

Date: 2026-08-28
Spec: 014, 020
Decision: 0026

## Result

M8 adds an optional Emacs control surface over the Termini App Server. The root
`termini.el` entry point loads a managed stdio bridge and native RuntimeSession
and job views. Ordinary `chat.el` loading remains independent and starts no
sidecar.

The bridge negotiates protocol `2026-07-08`, requires the stable session,
message and job methods, gates optional attachment and message operations and
correlates out-of-order JSON-RPC responses by numeric request ID. Reconnect
creates a fresh generation and never replays a mutation. Caller-generated
command, message and cancellation identities cross the bridge unchanged.

RuntimeSessions, messages, jobs, tails and attachments are validated bounded
projections. They retain no raw response copy and are not persisted as local
tasks. One local chat session may explicitly store only a remote
RuntimeSession ID for navigation.

## Correctness Details

- Split, coalesced, blank, malformed and unterminated oversized JSONL input is
  deterministic and bounded.
- Duplicate responses cannot complete a callback twice; unknown late responses
  cannot grow the completed-response table.
- Disconnect fails pending requests once and cancels their timers without
  inventing a terminal job state.
- Standard error is a separate bounded tail and never becomes job output.
- Empty method parameters encode as `{}`, not `null`.
- Job cancellation is offered only for accepted or running jobs. A conflict
  triggers an authoritative `job/list` refresh.
- Follow notifications trigger a public `job/tail` reread instead of rendering
  notification payload as trusted output.
- Attachment capability checks happen before local file access and decoded
  bytes have a configured ceiling.
- Closing Emacs or disconnecting closes every sidecar and stderr pipe owned by
  the bridge.

## Verification

The canonical suite passes 1539/1539 with zero unexpected results. Twenty-eight
focused offline tests cover the protocol, projections, lifecycle, optional
entry point and native views. Touched Lisp files pass `check-parens` and byte
compilation.

The first foreground live smoke exposed an uninitialized M6 execution backend;
the bridge now initializes it only when connecting. The second exposed empty
params encoded as JSON `null`; the bridge now sends an empty object. The final
smoke negotiated protocol `2026-07-08`, entered `ready`, listed five
RuntimeSessions, shut down cleanly and left no App Server process behind.

## Follow-Up Boundary

Additional local transports may implement the same negotiated client contract.
They must not make views parse Termini state files, persist remote jobs as local
tasks or retry mutations with a new identity.
