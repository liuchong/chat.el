# Spec 030: Delayed Model Switching

## Purpose

Model choice is request state, not mutable decoration. A selection made while a
request is in flight must never relabel or alter that request. The chat therefore
keeps three explicit identities:

1. **active target**: provider and concrete model used by the request currently in
   flight, or by the most recently started request;
2. **prepared target**: provider and concrete model shown at the input prompt and
   captured by the next message the user sends;
3. **pending switch**: an explicit operation waiting to become active at the next
   request or continuation boundary.

Provider and concrete model form one atomic target. No state may contain a provider
from one vendor paired with a model name from another.

## Prompt Selection

Clicking the model segment only changes the prepared target. It sends no message,
does not cancel or mutate a run, and does not immediately change the active target.
While prepared and active targets differ, the prompt appends `(*)` to the model
name. Sending a real message commits the target captured at that send boundary and
removes the marker only when that exact target becomes active.

Choosing another prompt target supersedes an un-applied explicit switch. This is a
deliberate replacement, not a second queued operation. Supersession clears the
matching operation from both session state and an active Agent run by operation
ID; it cannot accidentally clear a newer operation.

## Explicit Model Command

`/model TARGET` creates a pending switch without asking the model and without
interrupting an active run. `TARGET` accepts a configured provider, a
`provider/model` pair, or a model name that resolves to exactly one configured
provider. Ambiguous and unknown targets are rejected without changing state.

The command updates the prepared prompt target immediately. Before application it
is rendered as an uneditable transient row at the bottom of the transcript, after
all committed and live response output and before the input work shelf. At the next
request boundary the switch is applied atomically, the transient row disappears,
and a display-only command record enters durable transcript history. It is never
sent back to a model.

If an active run ends before another model request is needed, the operation remains
pending. The next real message applies it; the command alone never creates an empty
model turn.

## Send Modes

Every submitted message captures its prepared target at submission time.

- **idle send** applies the captured target before starting the new run;
- **insert** attaches the captured target to the steering operation and applies it
  immediately before the next continuation request, after the current request has
  completed;
- **queue** stores the captured target in the structured queued item and applies it
  when that item starts its own run, regardless of later prompt selections;
- **interrupt** cancels the old run and applies the captured target to the new run;
- subsequent continuation steps keep the newly active target until another switch
  is applied.

Applying a target updates the run provider, concrete model and request options as
one transition. Retries of an already-started request retain that request's target.

## Hints And Completion

After `/model `, a passive non-selectable hint lists bounded configured
`provider/model` targets. It owns no cursor, focus, `RET`, arrow key or selection
state. `RET` always dispatches the typed command exactly as written.

`TAB` completion is independent of the hint. It completes the only candidate or
the exact common prefix of multiple candidates and never opens a selection UI.

## Persistence And Evidence

Active, prepared and pending state are session-owned and survive reopening.
Applied switches emit a structured agent event and append a display-only transcript
record carrying operation ID, provider, model and source. A pending operation is
single-slot latest-wins state. Operation IDs prevent late events from consuming a
newer switch, and one operation cannot be applied twice.

## Acceptance

Tests must prove:

- prompt selection changes only prepared state and displays `(*)`;
- an in-flight request retains its original provider and model;
- an explicit command does not cancel or immediately dispatch a model request;
- exactly the next continuation consumes a pending switch once;
- later continuation requests retain the switched model;
- idle, insert, queue and interrupt each use the target captured at send time;
- a queued message is unaffected by later prompt changes;
- a switch left pending when a run ends applies to the next real send;
- application replaces the transient row with one durable display-only record;
- an open work shelf remains below the transient row while live output grows,
  without losing shelf content or moving the input boundary;
- direct command switching updates the prompt target;
- unknown and ambiguous targets leave all state unchanged;
- passive hints and common-prefix completion remain non-selectable and bounded;
- session reopen preserves prepared and pending state;
- the canonical test suite remains green.
