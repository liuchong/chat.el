# Durable Work Plans

- Type: record
- Attention: reference
- Status: complete
- Scope: coding-agent-reliability
- Tags: plan, todo, context, ui, evidence

## Result

M14 adds one durable plan record per coding objective without creating a second
task, event or evidence store. Plan and item schema version 1 persist in session
metadata, mutate through optimistic revisions and recover interrupted work as an
explicit blocked state. The programming profile exposes nine plan operations.

The real enforcement point is the tool boundary. A plan that merely exists is
not sufficient: governed work requires an applicable active plan and one
dependency-ready `in-progress` item. Completion requires evidence already known
to the same session and task. Simple single-target mutations use a durable skip
that is consumed once; read-only and answer-only work remain free of ceremony.

## Context And UI

The durable record, Agent projection and UI projection are separate views of one
truth. The Agent receives at most 2,000 characters containing the objective,
current item, acceptance, direct blockers, bounded remaining titles, aggregate
progress and only evidence added since its previous projected revision. Complete
history stays behind the read tool instead of becoming recurring prompt tax.

The native chat region is inserted immediately above the input marker and owns
only buffer-local fold state. Replacing that region preserves point and every
window's start; it creates no timer or overlay and never redraws the transcript.
Fixed textual status markers keep CJK titles and terminal rendering predictable.

## Lessons

- Persist IDs and transitions; derive compact prompt and UI projections.
- Enforce plans where actions execute, not only through prompt instructions.
- Require a current item so an empty plan cannot become blanket authorization.
- Resolve evidence by session/task scope and store references, not copied output.
- Track the last projected revision so completed evidence appears once when useful.
- UI stability needs a 1,000-update test; visual inspection cannot prove point or scroll invariants.

## Verification

- `chat-work-plan*`: 19/19 focused tests passed.
- Agent gate and ephemeral-context tests passed.
- Capability profile plan-tool surface test passed.
- Canonical suite passed 1,655/1,655 with zero unexpected results before documentation closeout.
