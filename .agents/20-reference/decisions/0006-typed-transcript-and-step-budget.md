# 0006 - Typed transcript, request projection, and the step budget

Status: accepted
Date: 2026-08-25

## Context

A run is a loop: the model reasons, calls tools, reads results, reasons
again, and only then answers. Both displays rendered that whole loop into a
single mutable region and redrew it on every event, so step N's output was
deleted when step N+1 arrived. The reader was left with the last step only,
which read as "the middle of my conversation disappeared".

The data was never lost. `chat-agent-transcript-persist-message` already
wrote the intermediate `:assistant` and `:tool` messages to the session. Only
the drawing threw them away.

## Decisions

### 1. The transcript is a typed part list, not one mutable slot

`chat-transcript.el` turns messages into an ordered list of parts, each with
a category (`user`, `ai-progress`, `ai-final`, `command-reply`,
`shell-output`, `system-detail`) and, for progress, a work kind (`thinking`,
`tool-call`, `tool-result`, `message`). A display appends parts and folds
them by channel instead of redrawing one region.

### 2. Structure is stamped by the producer, not inferred by the reader

The loop stamps `turn`, `step`, `category` and `work` on every message it
appends, and those survive a reload. Inference from role and tool calls
remains only as a fallback for sessions recorded before the stamps existed.

Position is never used to pick the answer. A last-one-wins rule mislabels a
run that stopped at its step limit as if it had replied.

### 3. What is stored is larger than what is sent

`chat-session-messages` doubles as the request context. That is why the
complete record was not being kept in the first place: anything added for
the reader would have been sent to the model on the next turn.

So the record is now the superset and the context is a projection of it:
`chat-transcript-model-messages` drops the categories that exist for the
reader alone. Reasoning stays out by living in message metadata, which is
never serialized into a request.

Exclusion keys off an **explicit** stamp only. An unstamped `:system`
message is a system prompt or a compaction summary, both of which the model
must see; excluding on the fallback category would have silently dropped the
model's own instructions.

### 4. Reasoning is a field on its step, not a record of its own

Reasoning belongs to the step that produced it, so it is stored there. A
separate record would need a new role and would hand every future request
path a standing obligation to remember to filter it. Storage completeness
and display are identical either way.

### 5. The step budget is disclosed in tiers

`chat-agent-max-steps` defaults to 300 and accepts `unlimited`. The
parameter stays in place when the ceiling is lifted, so a run can be capped
again without other changes.

Telling the model "N steps left" on every step is the obvious design and
mostly a mistake: with a large budget it is noise, and a countdown delivered
partway through a hard task reads as pressure to give up rather than to
focus, which shows up as runs abandoning work they could have finished.

The mechanism behind that failure is worth naming, because it also supplies
the fix. A run that learns its budget is shrinking infers that it must
produce a final answer immediately, and starts discarding work it was close
to finishing. So every message about the budget also states that running out
is survivable: the user can open another round that continues from the
summary. That turns a countdown from a reason to quit into a request to
converge, and it is why the wording matters more than the threshold.

Disclosure is tiered:

| Tier | Behaviour |
|---|---|
| System prompt | States the ceiling once, plus "running out is not a failure" |
| Comfortable | Silent |
| Tight (default 75%) | "Step N of M, K left. Start converging..." |
| Final step | Tools withdrawn; text-only handoff demanded |

Spending the last step on a handoff rather than letting the run die
mid-tool-call costs one step and buys an ending someone can resume from. The
alternative -- failing out with no output and leaving the user to type
"continue" -- pays the same step cost with nothing to show for it.

`chat-agent-budget-disclosure` selects `nearing` (default), `always`,
`final-only` or `never`.

Tools are withdrawn on the final step rather than merely forbidden, because
asking a model not to call tools is far less reliable than giving it nothing
to call.

The reminder is appended per request and never stored on the run, so a stale
count cannot repeat in later requests or settle into saved history.

## Consequences

- A display must render from `chat-transcript-plan`; it may keep one
  replaceable region for the streaming tail only.
- Any new request path must project through `chat-transcript-model-messages`.
  There are two: one per display.
- Per-display step ceilings (`chat-ui-tool-loop-max-steps`,
  `chat-code-tool-loop-max-steps`) default to nil and defer to the global
  budget, so the number has one home.
