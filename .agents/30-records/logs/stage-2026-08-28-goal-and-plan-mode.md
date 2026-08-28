# Durable Goal and Plan Mode

- Type: record
- Attention: reference
- Status: complete
- Scope: coding-agent-reliability
- Tags: goal, plan, todo, context, ui, evidence, approval

## Result

M17 adds a durable Goal contract with optimistic revisions, bounded history,
project scope, explicit pause/resume/block/complete/cancel transitions and
deterministic completion from known scoped evidence.  Active contracts project
as protected request context and stable native UI, while full progress remains
in the session record.  Automatic continuation is bounded and leaves an
explicit needs-attention state instead of looping indefinitely.

M18 adds an independent Plan Mode permission state.  Researching permits
read-only tools and dedicated structured note, Goal-progress and work-plan
updates.  Ready state freezes the submitted plan revision.  Source mutation,
execution, child work and unknown effects are refused at the tool boundary
until a user approves the exact submitted revision.

Goal, work plan/TODO, work note and runtime task remain separate records linked
by identifiers and events.  Plan and task lifecycle updates record Goal
progress but never infer objective completion.

## Compatibility

Legacy title/status goals migrate once to paused contracts while preserving
their IDs and titles.  Existing versioned Goal records remain authoritative on
an ID collision.  The retired add/update entries reject incomplete or
revisionless writes, while the legacy list entry reads the canonical Goal
store.  An old planning flag never activates or approves Plan Mode.

## Verification

- canonical batch suite: 1760/1760 passed with zero unexpected results
- Goal survived 20 turns, two compactions, session reload and restart together
  with linked TODO plan and structured notes
- unknown, cross-scope and missing evidence completion paths failed closed
- pause, block, resume, clear, stale revision and one-time migration paths passed
- Plan Mode effect matrix, exact-revision approval, rejection feedback and
  ready-state restart paths passed
- 1,000 interleaved Goal, plan and streaming projection updates preserved input
  point and window anchors
- M19 final acceptance requires nine typed Goal and Plan Mode reliability gates;
  missing or malformed measurements block instead of defaulting to zero

## Lessons

- Persist the completion contract; project only the bounded active slice.
- Enforce read-only planning at the execution boundary, not in prompt prose.
- Bind approval to immutable identity plus revision, never to a display string.
- Link plans, notes and tasks by scoped IDs rather than copying their bodies.
- Scope-safe UI must consume the same redacted projection as model context.
