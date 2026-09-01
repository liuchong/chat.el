# Deferred Long-Running Runtime Designs

- Type: stage-record
- Date: 2026-09-01
- Scope: design-only objective requirements
- Status: completed

## Trigger

The active objective required four future-facing areas to be preserved as
complete Specs without implementation: event subscriptions, remote Agent rules,
distributed/headless session execution and collaborative conversation groups.
M20 product qualification is simultaneously frozen and blocked on independent
TypeScript and Clojure toolchains, so this documentation stage had to remain
strictly independent of fixture, judge, campaign and provider code.

## Existing Facts Audited

- background commands already use durable unified runtime tasks;
- session wire, task, checkpoint, Goal, Plan and work-plan stores already have
  distinct authorities;
- structured message staging and all three runtime send modes are implemented;
- requirement admission, per-session recall, local pair channels, roles and
  topics are already designed in Spec 027;
- the Termini App Server bridge already defines a versioned optional protocol
  boundary;
- delayed model switching is already a complete active/prepared/pending state
  machine and was not duplicated;
- the complete M20 matrix remains blocked before provider use only by missing
  independent `tsc` and `lein` executables.

## Design Decomposition

The four requirements were deliberately not merged:

1. Spec 031 owns observation intent, source cursor, deterministic trigger policy
   and idempotent requirement admission. It does not own task execution.
2. Spec 032 owns remote source provenance, immutable rule bundles, validation and
   exact activation. It does not create a higher instruction priority.
3. Spec 033 owns runtime placement, UI attachment, lease generation, fencing and
   language-neutral protocol behavior. It does not duplicate session state.
4. Spec 034 owns group membership, channels, assignments and decisions. It does
   not merge member contexts or state machines.

This split keeps ownership testable. A universal remote-Agent record would have
mixed observation, authority, placement, communication and execution and made
failure recovery ambiguous.

## Important Decisions

- Waiting for an event consumes no model turn and no foreground Agent.
- Remote source bytes are untrusted data until a separately reviewed exact
  bundle revision is activated.
- Headless and UI-attached operation are two attachments to the same session
  runtime contract, not formats requiring conversion.
- A session has one fenced mutating runtime generation; disconnect is not a
  terminal task fact.
- Group delivery is data until each receiving session admits it; messages cannot
  become system instructions or tool execution directly.
- All future designs reuse existing Session, wire, Task, checkpoint, Goal, Plan,
  work-plan and admission authorities by reference.
- Pre-1.0 implementation will use one current schema and will not preserve
  experimental compatibility paths.

## Review Corrections

The first group lifecycle draft called `closed` terminal while also permitting
reopen. The final contract makes only `cancelled` terminal. Reopen creates a new
activation epoch under the same stable group ID, keeps prior history immutable
and redispatches no old work.

The project status still described M19 final campaigns as recommended future
work even though M19 and M21 are complete. It now names the actual M20 blocker
and exact resume order.

## Validation Contract

The Specs include executable future acceptance criteria for:

- duplicate delivery and mutation idempotency;
- restart at commit, acknowledgement and request boundaries;
- lease fencing and partition behavior;
- scope, authority and credential privacy;
- bounded payloads, indexes, event pages and UI projections;
- dynamic membership, leave/rejoin, channel ordering and assignment conflicts;
- explicit distinction among unavailable, stale, blocked, interrupted, timeout,
  cancellation and failure.

## Verification

- structural Spec audit: 4/4 files contain status, invariants, implementation
  sequence, acceptance and deferred-work boundaries;
- referenced Spec identity audit: 009, 016, 018, 020, 021, 022, 024, 027 and
  031-034 all resolve to one repository file;
- focused documentation ERT: 4/4, zero unexpected;
- canonical suite with the existing Rust toolchain visible: 2008/2008, zero
  skipped and zero unexpected;
- `git diff --check`: clean;
- prohibited external-project and obsolete repository-path scan: no match in
  the stage diff.

The first focused ERT command omitted the `tests` load path and stopped while
loading `test-helper`; no test body ran. The corrected invocation added `-L
tests -L tests/unit` and produced the 4/4 evidence above. The loader error is an
invocation error, not product evidence.

## Remaining Work

- No runtime from Specs 031-034 is implemented in this stage.
- M20 remains blocked until independent `tsc` and `lein` are explicitly
  available. The frozen matrix must not be reduced.
- Each future Spec requires its own stage, TDD/BDD fixtures, privacy review and
  canonical verification before implementation can be claimed.
