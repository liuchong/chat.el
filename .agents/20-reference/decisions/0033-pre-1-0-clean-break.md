# Decision 0033: Pre-1.0 Clean Break

- Type: decision
- Attention: reference
- Status: accepted
- Scope: product-architecture
- Tags: pre-1.0, clean-break, schema, commands, design

## Context

The product is not released, deployed or bound to an installed-user data
contract. Compatibility machinery added during exploration preserves accidental
interfaces, duplicates facts and makes each new design harder to reason about.
There is no user benefit that offsets that cost at this stage.

## Decision

Product-history compatibility is prohibited by default until an actual released
contract exists. This does not permit an implementation task to redefine or
break accepted design. Existing Specs, decisions and rules remain authoritative
until the design itself is explicitly changed. A failing test that encodes an
unchanged contract is a regression, not compatibility baggage.

Before behavior changes, identify the authoritative design. When a design change
is required, first revise every affected Spec, rule, data contract and interaction
into one complete, conflict-free replacement and state its scope. Design outside
that scope remains binding. Only then does the clean break apply: the same change
removes the old schema, command, configuration, cache shape, alias, implementation
path, tests and documentation.

Implementation work, refactoring and test cleanup cannot declare an unrevised
design obsolete. The clean-break rule is not grounds for removing tests that
still assert the current contract, weakening acceptance, bypassing constraints,
or changing behavior outside the formally revised scope.

Do not add migrations, fallback readers, compatibility wrappers, shims,
dual-writing, deprecation periods or permissive format guessing. Reject stale
state when rejection is useful; discard and rebuild it when it is derived.
There must be one canonical representation and one behavior for each concept.

Supported Emacs versions and externally required protocol versions are current
environment contracts, not product-history compatibility. They remain explicit
and tested, but must not be used as a reason to preserve obsolete internal
designs.

An exception requires an explicit user decision identifying a real released
contract, affected users, scope, evidence, and a removal condition. Speculative
future users are not an exception.

## Consequences

- New designs stay direct and internally coherent.
- Accepted design cannot be silently weakened under the clean-break label.
- Tests assert only the current contract.
- Rebuildable state is rebuilt instead of migrated.
- Work touching an old/new split removes the split within its stated scope.
- `AGENTS.md` carries the full rule in mandatory startup context; this record
  explains the architectural decision without being its only location.
