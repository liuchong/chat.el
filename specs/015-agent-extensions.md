# Agent Extensions

Status: implemented
Date: 2026-08-28
Roadmap: M3
Decision: 0021

## Goal

Let hooks, reusable skills and custom agents change runtime behavior without
forking the agent loop, branching on a provider name or widening a session's
authority. Resolution happens before dispatch and produces a bounded snapshot
that can be inspected and audited later.

## Trust Boundary

User manifests live under `~/.chat/skills/` and `~/.chat/agents/`. Project
manifests live under `.chat/skills/` and `.chat/agents/`, but remain inert until
their canonical project root appears in
`chat-extension-trusted-project-roots`.

Manifest files are JSON data. Discovery records filenames and precedence only;
the body is parsed when an identifier is resolved. Readers reject oversized,
malformed or future-schema manifests and never evaluate text from them.

## Runtime Hooks

`chat-runtime-hook` version 1 is a named declaration over `chat-event`, not a
second event bus. A declaration states:

- stable id, schema version, owner and source;
- blocker or observer phase and accepted event types;
- deterministic priority;
- handler and optional local timeout;
- project root when the source is project-local.

Blockers may target only lifecycle events that M1 marks blockable. Their
timeout and failure decisions therefore inherit the lifecycle fail-closed
policy. Observer failures remain isolated. Plugin-owned declarations join the
plugin rollback stack and are removed or restored when their owner stops.

## Skills

`chat-skill` version 1 contains an id, revision, description, instructions,
requested tools and model capability requirements. The id must match the
manifest filename. Explicit registrations outrank files; trusted project files
outrank user files.

Instructions and requirements become active only when a resolved profile names
the skill. A skill may narrow the effective run but cannot advertise or execute
a tool outside the authority already granted by the session and profile.

## Agent Profiles

`chat-agent-profile` version 1 can declare ordered parents, instructions,
provider and model preferences, required capabilities, skills, enabled and
disabled tools, approval mode, maximum steps, context budget, subagent limit
and background intent.

Resolution follows these rules:

1. parent profiles resolve left to right and cycles fail;
2. instruction fragments append in provenance order;
3. tool allowlists intersect and disabled tools union;
4. approval resolves to the stricter value;
5. numeric limits resolve to the smaller value;
6. skills add instructions and requirements but no authority;
7. known model capability conflicts fail before transport starts.

The selected profile id persists in the existing session tool configuration.
Each run receives a transient execution-session copy containing its effective
overlay, while the original transcript and earlier session messages remain
unchanged. A `profile-resolved` event stores a bounded reproducibility snapshot
with profile revision, source digest, model choice, skill revisions, effective
authority and conflict diagnostics.

Context-budget and background fields are part of the versioned shape so later
task and context stages can consume them. M3 resolves and snapshots these
fields; it does not claim task scheduling or a new context compaction policy.

## Compatibility

The existing code, office and daily capability commands remain available and
now also register built-in profiles. Existing session tool overlays retain
their meaning. Legacy Emacs hook registration remains compatible, while new
runtime extensions use named `chat-runtime-hook` declarations.

## Acceptance

- every extension uses the existing runtime and lifecycle contracts;
- project-local extension data is inactive until explicitly trusted;
- model conflicts fail before a request reaches a provider;
- no skill or profile silently widens tools or weakens approval;
- resolved behavior is inspectable, reproducible and session-audited;
- changing a profile does not rewrite history.
