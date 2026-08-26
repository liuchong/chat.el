# Stage log 2026-08-26 — questions belong in the prose, next to the plan

- Type: records
- Attention: log
- Scope: agent-workflow

## What prompted it

Agents kept putting decisions to the user through the editor's
structured-question controls — multiple choice popups, option lists,
confirmation dialogs. `AGENTS.md` had nothing to say about it either way.

## Why it is forbidden

The controls hold a label and nothing else. A decision worth putting to the
user carries the fact that triggered it, where in the tree that fact lives,
what each option costs, and which claims are verified against which are
guessed. None of that fits on a button, so the user is handed a row of
conclusions with no account of where they came from, and can only guess or
cancel. A cancelled dialog then reads as consent, or as a refusal to
decide, when all it means is that the question was unanswerable as posed.

## Where it went

Not into a section of its own. Asking the user to decide something is the
same act `Plan Before Business Code` already governed, and that section
already carried a four-item list of what a plan must contain — problem,
scope, options and trade-offs, recommendation. A second list beside it
would have said the same thing twice and then drifted.

So the list grew to six and the items gained their substance: the problem
names the triggering fact and what stalls without a decision, scope names
what the decision changes downstream, options name each one's premise, cost
and risk, and the recommendation names the condition that would flip it.
The two new items are the ones a popup structurally cannot carry — where
the evidence lives, by path and line, and which facts are verified against
which are still guesses. The section now opens by saying plans and
questions use the one form, and closes with the self-check: anything
readable from the code, the docs, a command or a log is not the user's to
answer.

The prohibition itself went to `Absolutely Forbidden`, which is the section
that exists for prohibitions, and points at `Plan Before Business Code` for
the form rather than restating it.

## Verification

Documentation only, no code touched. Suite unchanged at 945 passing.
