# Remote Scoped Agent Rules

Status: accepted design; implementation deferred
Date: 2026-09-01
Scope: remotely stored personal, organization and project rule bundles

## Goal

Allow explicitly configured rule bundles to be fetched from remote storage while
preserving deterministic scope, provenance, review and instruction authority.
This supports consistent personal and organization policy without concatenating
untrusted remote text directly into a system prompt.

This Spec defines the future contract only. It does not authorize fetching or
executing remote rules in the current objective.

## Existing Authorities

- repository and directory instructions remain structured fragments under Spec
  021, with canonical path scope and precedence;
- session, Goal, Plan and work-note state remain separate;
- plugin capabilities and approval policy govern network and credential access;
- Spec 009 records bounded fetch and activation facts;
- public export follows Spec 024 and excludes private rule bodies.

A remote rule source is transport and provenance. It does not create a new
instruction priority above system or developer policy, and source ordering cannot
override the existing authority lattice.

## Core Invariants

1. Remote bytes are untrusted until parsed, validated and activated.
2. Every effective fragment has source, immutable revision, digest and scope.
3. Fetch success never means activation success.
4. Rules cannot widen the authority of the source that supplied them.
5. Project rules cannot escape their canonical project or directory scope.
6. Stale, unavailable, invalid, conflicted and unauthorized states are explicit.
7. Model output cannot activate, approve or rewrite a rule bundle.
8. Offline use is pinned to a previously activated immutable revision, never the
   latest bytes found in a cache.
9. Secrets and credentials never enter rule content, diagnostics or exports.
10. The pre-1.0 implementation will use one current schema without migrations,
    fallback parsers or dual rule stores.

## Source Contract

`chat-rule-source` schema version 1 contains:

- stable source ID, revision, display name and owner identity;
- transport kind: `http`, `mounted-file`, `git` or installed adapter;
- typed endpoint descriptor and credential reference;
- declared authority class: `personal`, `organization` or `project`;
- canonical scope root and optional include/exclude selectors;
- pin policy: immutable object ID, signed manifest revision or explicit digest;
- refresh policy and bounded network/file capabilities;
- active bundle ID and revision;
- state: `inactive`, `fetching`, `ready`, `active`, `stale`, `blocked`, `failed`
  or `cancelled`;
- last checked, fetched, activated and failed timestamps;
- bounded failure and conflict summaries.

Transient connections, repository handles, timers and credentials are excluded.
`fetching` is reconstructed as `failed/interrupted` after restart. `cancelled` is
terminal. Activation and source lifecycle use optimistic revisions.

## Bundle Contract

A fetched `chat-rule-bundle` is immutable and contains:

- schema version, bundle ID, source ID and source revision;
- transport object identity, fetched timestamp and complete byte digest;
- optional signer identity and verified signature facts;
- declared scope roots and required authority class;
- ordered typed rule fragments;
- dependency references with exact immutable identities;
- parser version, normalized fragment digest and validation result;
- bounded provenance and review metadata.

Fragments use Spec 021 types and retain their individual scope, priority and
source reference. A bundle cannot contain executable Lisp, callbacks, arbitrary
reader forms, credential references, approval grants or dynamic includes.
Dependencies form a finite acyclic graph; every dependency is pinned and
validated before the bundle can become ready.

## Fetch, Review And Activation

Fetch writes an immutable candidate and emits a bounded event. It never replaces
the active bundle. Validation then checks schema, byte and fragment limits,
dependency graph, canonical scopes, signature policy, authority ceiling and
conflicts with higher-priority rules.

Activation is a separate explicit operation naming the exact candidate revision
and digest. The UI presents source, scope, added/removed/changed fragment counts,
authority effects and validation failures before activation. Personal and
organization policy may require separate approvers. Project content can request
only project-scoped authority.

An active bundle remains effective until another exact revision is activated,
the source is disabled, or policy revokes it. A failed refresh leaves the prior
activated immutable revision effective but visibly `stale`; it never silently
switches to partial or unverified bytes.

## Scope And Precedence

Effective context is assembled from structured fragments, not file concatenation.
The resolver evaluates:

1. platform system and developer policy;
2. organization policy permitted for the current identity;
3. personal policy permitted for the current identity;
4. project and nested-directory policy for the canonical target path;
5. session and task-scoped non-authoritative working context.

Within one authority class, more specific canonical path scope wins only where
the schema declares an overridable field. Non-overridable conflicts block
activation. Textual order, fetch time and source URL never raise precedence.
Symlink, case and path alias resolution use the same canonical path contract as
Spec 021.

The Agent receives a bounded effective projection with fragment IDs, source
identities, scope and content required for the current action. It can query
provenance on demand. Bundle graphs and unrelated rule bodies never become
resident prompt context.

## Transport And Credentials

Built-in transports support bounded HTTP objects, mounted files and hosted or
ordinary Git repositories. Installed transports obey the same adapter and trust
rules. Network redirects, submodules, includes and repository hooks are disabled
unless the transport contract explicitly supports and scopes them.

Credentials are resolved only at fetch time from the configured credential
provider. Durable state keeps an opaque reference, never a value. Fetch logs
record endpoint class, revision, byte counts, duration and redacted failure, not
authorization headers, complete URLs with secrets or repository contents.

## Public Operations

- create, inspect, enable, disable and cancel a source;
- fetch one immutable candidate and inspect validation results;
- compare candidate and active normalized fragments;
- activate an exact digest with expected source revision;
- list effective fragments for a canonical path and action;
- trace one effective rule to source, bundle and fragment identity;
- refresh without activation;
- remove a source and its inactive candidates after impact confirmation.

## Failure And Recovery

- unavailable transport leaves the active revision intact and marks stale;
- changed content at a pinned identity is an integrity failure;
- future schema, cycle, duplicate fragment ID or scope escape blocks activation;
- partial download is discarded before candidate publication;
- disk failure cannot advance active bundle metadata;
- restart may resume a fetch only by starting a new attempt; it never reuses a
  transient response body;
- deleting an active source requires explicit replacement or deactivation and
  records the resulting effective-rule change.

## Implementation Sequence

1. Freeze source, bundle and fragment schemas plus authority resolution.
2. Build deterministic local fixtures for fetch, dependency and signature facts.
3. Add immutable candidate storage and atomic activation pointer.
4. Integrate the Spec 021 structured resolver and provenance projection.
5. Add transports behind explicit capabilities and credential references.
6. Add native review, diff, stale and conflict surfaces.
7. Run path, integrity, privacy, restart and adversarial-content evaluations.

## Acceptance

- activating a candidate changes effective rules only at its declared scope;
- one changed byte changes the bundle digest and cannot pass a pinned identity;
- a failed refresh never changes the active normalized fragment set;
- 10,000 fragments resolve through bounded indexed lookup without prompt growth;
- cyclic dependencies, future schemas, scope escapes and authority widening fail
  before activation;
- symlink and path aliases produce the same effective scope result;
- model-generated content cannot activate or approve a candidate;
- credentials and private rule bodies are absent from wire, diagnostics and
  public export;
- restart reproduces the exact active digest and effective fragment projection;
- canonical and dedicated deterministic suites pass with zero unexpected result.

## Deferred Work

- implementing transports, storage or UI in the current objective;
- public rule-bundle distribution;
- implicit discovery of remote sources from repository text;
- mutable "latest" activation without an immutable identity;
- compatibility with experimental pre-1.0 rule formats.
