# Structured Work Context And Scoped Instructions

Status: implemented
Date: 2026-08-28
Roadmap: coding reliability M13

## Goal

Keep long-running work coherent across model turns, context compaction and
restart without turning the prompt into an unbounded concatenated document.
The runtime stores typed context fragments and short-lived working notes with
explicit authority, provenance and scope. Provider messages and UI text are
projections over that state.

## Boundaries

This contract does not replace:

- the transcript, which remains the complete conversation record;
- `chat-memory-item`, which remains attributable long-term memory;
- session scratch files, which remain temporary arbitrary artifacts;
- `chat-task`, which remains schedulable work lifecycle;
- `chat-work-plan`, which owns ordered TODO state.

A working note records what the current task must remember. It is evidence or
working state, never an instruction merely because an Agent wrote it.

## Context Fragment Contract

`chat-context-fragment` schema version 1 contains:

- stable ID, schema version and content digest;
- kind: `system`, `instruction`, `objective`, `working-note`, `history`,
  `code`, `tool-schema`, `runtime-fact`, `verification` or `artifact`;
- authority: `system`, `user`, `project`, `runtime`, `agent` or `untrusted`;
- source kind, source ID, optional canonical path and source range;
- scope and scope ID;
- priority, residency and budget policy;
- typed payload plus bounded metadata;
- creation/update time and active, superseded or archived status.

`chat-context-bundle` contains the target session, turn, task, project and
path, the ordered selected fragments, omitted-fragment diagnostics, token
measurements and a deterministic bundle digest.

The runtime keeps standing-context fragments separate. Transcript history and
the current objective remain typed `chat-message` records; native tool schemas
remain structured request options. A transport adapter may serialize fragments
to provider messages only after scope filtering, authority ordering, budget
selection and diagnostics have completed. A serializer must preserve source
labels and cannot merge an Agent note into an instruction message.

## Scope Contract

Supported scopes are:

| Scope | Match |
|---|---|
| `global` | every request |
| `project` | one canonical project root |
| `directory` | canonical path is inside one directory subtree |
| `path` | one exact canonical path |
| `session` | one session ID |
| `turn` | one session and turn ID |
| `task` | one task ID |
| `child-task` | one child task and its declared descendants |

Path matching resolves existing symlinks before comparison. A missing target
uses its canonical existing parent plus basename. Project and personal/global
sources stay distinct in provenance even when both apply. Scope mismatch is an
omission with a reason, not silent deletion.

Ordering is deterministic:

1. authority;
2. scope specificity;
3. project directory depth for project instructions;
4. explicit priority;
5. source order and stable ID.

Higher precedence does not erase lower precedence. Conflicting or shadowed
fragments remain inspectable and are reported in bundle diagnostics.

## Project Instruction Graph

`chat-project` discovers the optional global AGENTS source followed by project
AGENTS files from filesystem root to the target path. Each file becomes a
separate instruction fragment whose directory defines a subtree scope.

An AGENTS file may declare dependencies with a hidden JSON directive:

```markdown
<!-- chat-agents: {"include":[".agents/00-entry/current.md"]} -->
```

Includes are relative to the declaring file unless project-root relative paths
begin with `/`. They must resolve inside the trusted project root. Included
files inherit the declaring fragment's scope and authority but keep their own
source path, digest and parent edge. Includes cannot grant wider scope.

The loader enforces:

- canonical-path containment and symlink-escape refusal;
- cycle detection with a visible diagnostic;
- maximum depth 8;
- maximum 64 source files;
- maximum 256 KiB source bytes before normal context budgeting;
- one read per unique digest during a bundle build;
- cache invalidation on source set, file modification stamp or graph
  configuration change; explicit cache clear handles preserved timestamps.

Unsupported or malformed directives leave the ordinary Markdown content
available as instructions but do not load dependencies. A dependency failure
is visible and cannot make a successfully read parent disappear.

## Working Note Contract

`chat-work-note` schema version 1 contains:

- stable ID, key and revision;
- kind: `fact`, `decision`, `constraint`, `hypothesis`, `artifact`, `blocker`,
  `next-step` or `note`;
- typed JSON-safe value and optional bounded display text;
- tags and related IDs;
- session, task and optional path scope;
- source kind and source ID;
- confidence and verification state;
- active, resolved, superseded or archived status;
- timestamps and bounded metadata.

The store is session-owned, atomic and schema-versioned. It maintains indexes
for `(scope, key)`, kind and tag. Upsert requires the observed revision when a
key already exists; stale updates fail with the current revision. Superseding
preserves both IDs. Delete and archive are explicit and emit events.

Prompt projection contains only applicable active notes. It favors objective
support, unresolved blockers, accepted decisions and next steps. Hypotheses are
labelled as unverified. Full note history is queried on demand instead of being
injected every turn.

## Compaction And Recovery

Each request emits the selected bundle identity and rebuilds the active work
slice from durable typed state, not from summary wording. Existing transcript
compaction continues to own conversation summaries. The following cannot be
lost merely because history was compacted:

- current objective and user constraints;
- active project instructions and resident spans;
- unresolved blockers;
- accepted decisions and next step;
- verification state needed to avoid a false completion claim.

The current plan item joins this projection when Spec 022 is implemented.

Restart loads the work-context schema without starting tasks or processes.
Malformed future schemas fail before rewrite. Missing state means an empty work
context and does not alter an old session.

## Public Operations

- build and inspect a context bundle;
- explain why a fragment was selected or omitted by status, scope or budget;
- list/query/get/upsert/resolve/supersede/archive/delete work notes;
- list the project instruction graph and its diagnostics;
- project the bounded active work slice for one Agent turn.

## Events And Trace

Events include aggregate bundle build, instruction graph diagnostics and note
lifecycle/conflict transitions. Per-fragment selection and omission reasons
remain on the inspectable bundle. Payloads contain IDs, scope, digest, status,
counts and bounded reasons, never complete prompts or sensitive note values.

Trace reports candidate/selected/token counts, scope refusals, dependency
cycles, truncations and note query/hit/conflict counts.

## Acceptance

- the scope corpus selects every applicable AGENTS source and no sibling or
  unrelated project source;
- include cycles, traversal and symlink escape are refused deterministically;
- Agent notes cannot obtain instruction authority;
- stale note revisions are refused without changing durable bytes;
- blocker, decision and next-step notes survive compaction and restart;
- code context and every applicable project instruction remain separately
  attributable until request projection;
- every selected and omitted fragment has an inspectable reason;
- 8K, 32K and 128K bundle selection is deterministic and bounded;
- legacy string prompt callers retain their behavior through adapters;
- canonical tests pass with zero unexpected results.
