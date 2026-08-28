# 0029 - Capability-Tested Execution Isolation

- Type: decision
- Attention: reference
- Status: accepted
- Scope: agent-runtime
- Tags: execution, isolation, capability, network, process

## Context

Approval can decide whether a command is intended, but it cannot constrain the
command after launch. A backend name is also not evidence that filesystem,
network, environment and descendant cleanup behave as claimed on the current OS.

## Decision

Adopt Spec 023. Restricted requests declare policy requirements independently of
backend identity, and a backend may satisfy them only with measured capability
facts. `inspect` and `build` deny network; `networked-build` consumes a fresh
request/session-bound approval. Missing capability blocks without local fallback.
Unrestricted local execution remains an explicit and honestly labeled option.

## Consequences

Project commands gain a second boundary after approval, and platform regressions
become visible as unavailable capability instead of silent loss of isolation.
The first backend is Darwin-specific and depends on a deprecated platform API,
so the contract deliberately supports replacement rather than treating that
implementation as portable.
