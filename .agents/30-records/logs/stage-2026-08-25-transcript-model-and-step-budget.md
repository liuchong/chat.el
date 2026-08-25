# Stage 2026-08-25 - Typed transcript model and step budget

## Goal

A run that used tools showed only the first question and the last answer;
every intermediate step was missing from the display. Establish a typed
transcript model that keeps all of it, and give a run an explicit step budget
that it can plan against.

## Root cause of the missing steps

Both displays drew a whole assistant turn into one mutable region and redrew
it on every event, deleting from the region start to the end marker each
time:

- `chat-code--replace-response-slot`
- the equivalent delete in `chat-ui--render-response-state`

A run emits reasoning, prose, a tool call, its result and more prose, so each
step overwrote the previous one. Reproduced in batch: rendering two contents
into one region leaves only the second.

The session file was never at fault.
`chat-agent-transcript-persist-message` already stored the intermediate
`:assistant` and `:tool` messages.

## Delivered

### `lisp/core/chat-transcript.el`

- Category and work-kind taxonomy; parts derived from existing messages.
- `turn`, `step`, `category`, `work` stamped by the producer and persisted;
  role-based inference kept only as a fallback for older sessions.
- `chat-transcript-turns` exposes the real shape: one question, its ordered
  steps, one answer.
- `chat-transcript-plan` groups consecutive parts of a channel into fold
  groups under a per-channel style (`collapsed`, `latest-expanded`,
  `expanded`).
- Faces per kind, including italic for a run's interim prose.
- `chat-transcript-model-messages` projects the record down to what a
  request may carry.

### `lisp/agent/chat-agent-budget.el`

- `chat-agent-max-steps` now 300, accepting `unlimited`.
- Tiered disclosure via `chat-agent-budget-disclosure`.
- Wording states that running out is survivable, which is what stops a run
  from quitting early when it hears a countdown.
- Final step withdraws tools in `chat-agent--options-for-turn`, and the
  reminder is appended per request without being stored on the run.

### Wiring

- Both request paths project through `chat-transcript-model-messages`.
- `chat-tool-caller-build-system-prompt` takes an optional step limit and
  states the budget once, only when tools exist.
- Per-display ceilings default to nil and follow the global budget.

## Verification

`emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`:
680 tests, 0 unexpected.

New coverage:

- 27 transcript tests, including a regression that every step of a
  multi-step run survives, and that the answer is never chosen by position.
- 19 budget tests, including silence early in a large budget, escalation
  when tight, and the reassurance wording.
- 6 loop tests: reminder reaches the request last, does not persist into the
  transcript, tools withdrawn on the final step and present before it, and a
  run completes with an `unlimited` ceiling.

## Not done in this stage

- Neither display renders from `chat-transcript-plan` yet, so the missing
  steps are still missing on screen. The model and the projection are in
  place; the drawing is the next stage.
- No fold interaction yet.
- Context budget is untouched: no model window awareness, nothing told to the
  model about context usage, and the compaction protected region
  (leading system messages) is still uncapped.
- The `auto` mechanism and the `/subagent`, `/send`, `/call_ai` specs are
  still pending.
