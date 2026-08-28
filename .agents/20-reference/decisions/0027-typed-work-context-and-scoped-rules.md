# 0027 - Typed Work Context And Scoped Rule Graphs

- Type: decision
- Attention: reference
- Status: accepted
- Scope: agent-runtime
- Tags: context, instructions, scope, notes, compaction

## Context

The runtime already has a transcript, long-term memory, scratch files and a
context budget, but request assembly still turns several sources into broad
strings. Source boundaries, authority and directory scope then survive only as
labels inside text. Compaction can preserve text without preserving the
identity of the objective, blocker or next step.

## Decision

Introduce versioned context fragments, bundles and session/task working notes
as specified by Spec 021. Keep authority and scope machine-readable until the
provider serialization boundary. Represent AGENTS sources and explicit
dependencies as a bounded graph; every source retains path, digest, parent and
directory-subtree scope.

Working notes are short-lived Agent evidence. They cannot become project rules
or long-term memory implicitly. Compaction reconstructs the active work slice
from typed state rather than relying on summary wording.

## Consequences

Context selection and omission become explainable, nested project rules stop
leaking into siblings, and an Agent can recover current decisions after
compaction. The cost is a versioned store and adapters for existing string
callers. Those adapters are temporary compatibility boundaries, not a second
context model.
