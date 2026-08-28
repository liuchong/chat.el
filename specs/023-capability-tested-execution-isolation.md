# Capability-Tested Execution Isolation

Status: complete
Date: 2026-08-28
Roadmap: M15
Decision: 0029

## Goal

Limit what model-directed commands can actually read, write, inherit and reach
over the network. Approval remains an intent decision; execution policy is a
separate operating-system enforcement boundary whose claims must be measured.

## Contracts

Execution request schema version 2 adds `policy`, canonical `read-roots` and
`write-roots`, `network`, allowed environment keys, required process-tree cleanup
and a transient network authorization ID. Durable records never store environment
values or network tokens. Version-one requests migrate to explicit `local`.

Every backend publishes measured facts for filesystem, network, environment,
timeout, process-tree cleanup, platform and availability. A request starts only
when its selected backend can enforce every required fact. Backend mismatch and
platform unavailability return explicit blocked errors; no restricted policy can
fall back to unrestricted local execution.

## Policies

- `local` is an explicit unrestricted user choice and retains inherited environment behavior.
- `inspect` reads only canonical project roots, writes nowhere and has no network.
- `build` reads and writes declared project roots and has no network.
- `networked-build` has build access plus network after a fresh shared approval and Guard decision.

Network authorization is opaque, bound to request and session identity and
consumed once. Retry requires a new decision. Approval and Guard continue to own
their existing session audit records; execution emits correlated policy and
network facts without creating another approval store.

## Darwin Backend

The Darwin backend is registered only with the result of a bounded foreground
`sandbox-exec` deny-default probe. Each process receives a generated profile,
canonical project roots, a backend-owned temporary HOME/TMPDIR, a filtered
environment, optional backend timeout and a private process group. The backend
derives Xcode developer and SDK paths and resolves Apple tool shims to real
binaries so compilers work without granting writes to the system user temp
directory.

Terminal exit, timeout, explicit cancellation and start-preparation errors all
remove backend temporary state. Timeout and cancellation send TERM and then KILL
to the process group, covering descendants as well as the leader.

The backend is platform-specific and replaceable. Its availability string is a
measured runtime fact, not a compatibility promise; an OS change can make the
same policy unavailable until a different backend is implemented and tested.

## Integrations

Read-only shell commands use `inspect`. Background tasks and project verification
use `build`. Existing MCP, external subagent and transport processes remain
explicit local paths until their own policy requirements are designed; they are
not relabeled as isolated.

## Acceptance

- project reads succeed while project-external reads fail;
- project writes and real Clang compilation succeed;
- parent writes and symbolic-link escapes fail;
- inspect/build network bind fails and approved networked-build bind succeeds;
- undeclared environment variables and the real user HOME are hidden;
- backend mismatch and missing platform capability fail before process creation;
- timeout and cancellation remove shell children, listeners and temporary roots;
- backend preparation failure removes a temporary root created before process start;
- v1 records load as local without replay;
- shell, background task and verification adapters preserve their existing behavior.

## Verification

The foreground probe reported Darwin `scoped` filesystem, `controlled` network,
`explicit` environment, timeout and process-tree cleanup as available. Sixteen
focused execution tests and forty-seven adapter tests passed with zero unexpected
results. Process, listener and temporary-directory scans were empty after the
tests. The canonical suite result is recorded in the M15 stage log.
