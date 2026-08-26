# Stage log 2026-08-26 — asking the user in prose, not in a dialog

- Type: records
- Attention: log
- Scope: agent-workflow

## What prompted it

A standing instruction that agents must not put questions to the user
through the IDE's structured-question UI — multiple choice popups, option
lists, confirmation dialogs, form questionnaires — existed only outside the
repository, so it applied to one tool on one machine and travelled with
neither.

## Why the rule exists at all

The controls hold a label and nothing else. A question worth asking carries
the fact that triggered it, where in the tree that fact lives, what each
answer costs, and which parts are verified against which are guessed. None
of that fits on a button, so the user is shown a row of conclusions with no
account of where they came from, and can only guess or cancel. A cancelled
dialog is then easy to misread as consent or as refusal to decide, when
what it actually means is that the question was unanswerable as posed.

## Where it went

`AGENTS.md`, as a new `## Asking The User` section, in four parts: the
prohibition, what a question must contain, what to check before asking at
all, and what to do having already popped one.

`AGENTS.md` is the only rule file in this repository that declares itself
binding on every agent and IDE plugin, and it is the only one that travels
with a clone. `.cursor/rules/` reaches one editor.

One copy, deliberately. The single existing file under `.cursor/rules/`
mirrors the `Documentation Must Be Updated` section of `AGENTS.md`, and the
two have already drifted — the mirror names `docs/PROJECT_STATUS.md` and
the original does not. That is the argument against making a second copy of
this rule: a duplicated rule is a rule that will disagree with itself, and
then neither version can be trusted.

## Verification

Documentation only, no code touched. Suite unchanged at 945 passing.
