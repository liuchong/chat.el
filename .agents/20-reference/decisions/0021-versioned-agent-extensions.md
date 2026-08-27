# Decision 0021

- Type: decisions
- Attention: reference
- Status: accepted
- Scope: agent-runtime
- Tags: hooks, skills, profiles, trust, composition, authority

## Title

Resolve versioned extensions before dispatch without widening authority

## Context

The runtime already had lifecycle events, session tool overlays, capability
packs, plugins and several Emacs hooks. They were useful extension points but
did not form one inspectable custom-agent contract. Copying the agent loop for
each role would duplicate cancellation, tool, audit and provider behavior;
loading project Lisp automatically would also turn a convenience feature into
an implicit code-execution boundary.

Profile composition adds a subtler risk. Instructions, skills and inherited
tool lists can look declarative while silently granting more authority than the
session had before. Model preferences can likewise fail only after dispatch if
their required capabilities are not resolved first.

## Decision

Runtime extensions use three version 1 contracts.

`chat-runtime-hook` is a named declaration over the M1 lifecycle event bus.
Blocker declarations inherit M1 ordering, timeout and fail-closed behavior;
observers inherit failure isolation. Plugin-owned declarations participate in
the existing reverse-order rollback stack. There is no second lifecycle bus.

`chat-skill` is declarative data containing instructions, requested tools and
capability requirements. Discovery indexes paths and precedence without
parsing bodies. A body is read only when a profile resolves that id, and it is
never evaluated.

`chat-agent-profile` composes ordered parents, skills, model preference, tools,
approval and limits before a run starts. Tool allowlists intersect, disabled
tools union, approval can only become stricter and numeric limits choose the
smaller value. Skill tool requests must fit inside the resulting authority.
Known model capability conflicts fail before transport creation.

Project-local hooks, skills and profiles are inert unless their canonical root
is explicitly trusted. Trusted project manifests outrank user manifests;
explicit in-memory registrations outrank both. Every source carries provenance
and file-backed declarations carry a digest.

Profiles execute through a transient session copy. The selected profile id is
session state, but resolved instructions are not appended to historical
messages. Each run emits a bounded `profile-resolved` snapshot to the existing
session audit projection.

## Consequences

Custom agents share one loop and therefore inherit the same cancellation,
approval, tool execution and model transport behavior. A profile can tighten a
session without becoming a hidden privilege source. Replaying a run can inspect
the exact profile revision, source digest, skill set and effective limits that
were resolved at dispatch time.

The manifest shape reserves context-budget and background intent for later
roadmap stages. M3 composes and records those values but leaves actual durable
task scheduling and new context policy to M4 and later work.

Legacy capability commands and Emacs hooks remain compatibility surfaces. New
extensions use the versioned declarations, allowing migration without a flag
day.

## Verification

The canonical suite passes 1430/1430. Focused extension tests cover
deterministic hooks, blocker timeouts, trust, plugin rollback, lazy discovery,
precedence, future schemas, inheritance cycles, capability preflight, authority
intersection, approval monotonicity, subagent limits, session selection and
history-preserving run snapshots.
