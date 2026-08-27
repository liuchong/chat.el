# Stage: the approver and its floor

Spec 013. `auto` became `guarded`, and a model does the approving.

## What was wrong

The middle mode was named for something it did not do. `auto` ran the fast
path for grants, then a fixed rule list, then refused without asking —
`manual` with the question suppressed. Worse than `manual` for the user,
because they lost the ability to say yes; no better for safety, because the
list was the same list.

The report that found it was a single incident: an agent asked for git
commit logs, `git` was not in `chat-tool-shell-allowed-commands`, and the
run spent eight minutes discovering that. Three separate faults in one
event. The refusal text did not say what was refused or that another
approach was allowed, so the model retried. `work_background_task` reached
a shell through `sh -c` and so did not meet the same gate, which made the
restriction advisory. And approval and the tool's gate were two independent
checks, so a command a person had just read and approved could still be
refused for not being on a list.

## What was built

`lisp/core/chat-approval-guard.el`. One neutral request per call that
reaches the mode branch, against a system prompt in two parts: an immutable
preamble the user cannot edit, and policy rules the user can extend.
Verdicts are structured, and an allow needs `decision: allow`,
`confidence: high` and a non-empty `matched-rule` — prose, bad JSON, an
abstain, a hedge, a timeout and a missing provider all refuse.

The payload carries facts and no narrative: environment (working
directory, project root, path boundary, session id, mode, disabled tools,
subagent depth), the arguments labelled untrusted, relative paths shown
both as written and as resolved, and the gate's own objection as evidence.
No conversation history, no task text, no word from the executing model.

`chat-approval-guard-never-allow-p` is the floor: writes outside the
boundary, deleting a home or a project root, rewriting published history, a
credential and the network in one command, edits to the approval records
themselves. Evaluated before any request, so a call it recognizes costs no
model call and enters no sample.

In `chat-approval.el`, the fast path moved ahead of the mode branch and
became a function with a sentinel for "no opinion" — nil is a decision
here, and returning it for "nothing to say" would run the mode branch after
a refusal. `chat-approval-authorize-async` is the live entry point;
`chat-approval-authorize` stayed synchronous and now refuses under
`guarded` when a guard is available rather than falling back to the rules
the guard replaces.

Shadow running: the guard runs alongside any mode, decides nothing, and
records its verdict against what actually happened, with the kind of
reference noted (person, rules, none) because a tired person's fortieth
allow is a noisy label. Samples export as JSONL. It ships off.

## What the work found

**Consent is the whole mechanism, and it is one line.** A verdict that does
not satisfy `chat-approval-command-consent-p` is decoration: the tool's gate
runs again and refuses what the guard just allowed. That single `memq` is
what the eight-minute incident was about, one layer up.

**The floor was silently disabled for its first hour.** Every predicate
returned nil, because command parsing was reached through `fboundp` and
`chat-command-gate` was not loaded. A conditional dependency on the module
the safety floor is made of is not a dependency. It is now a hard
`require`.

**`git -C /tmp push -f` walked through the history-rewrite check.** The
subcommand was found by dropping dash-words, and `-C` takes a value, so
`/tmp` was read as the subcommand. Global options that consume a value are
now listed and skipped with their argument.

**Two authorization points made a grant apply to half the tools.** Which
check ran depended on whether a tool declared an `async-function` — the
same grant took effect for one tool and not for another with the same name
and arguments. Authorization is now once, before the split.

**A default written at twenty construction sites.** `usage-count` had no
default in `chat-forged-tool`, and all twenty sites wrote `:usage-count 0`.
The twenty-first — a test — registered cleanly and died where the counter is
incremented, a layer away from the omission. The default moved into the
struct.

**An erroring test broke a passing one.** That same death left state
behind, and the failure surfaced in a working-directory test later in the
alphabet. A `let` unwinds on a signal but does not undo what the body
already did. Confirming the direction took one run with the suspect renamed
to sort last.

**Shadow under `guarded` had to hand the decision back.** The first
implementation let the guard decide and compared it against itself, which
measures nothing. Shadow means the guard decides nothing, in every mode
alike — so `guarded` plus shadow falls back to the rules while the guard
watches. Deliberate degradation, chosen by setting the switch, and the
reason the switch ships off.

## Held back, on purpose

Speculative pre-warming — starting a verdict before the call is complete —
is deferred. Accuracy first: a faster wrong answer is worth less than a
slower right one, and there is no data yet to say which calls would be
worth pre-warming.

Shadow running defaults off, at a stated cost: samples will come only from
people who turn it on, who may not represent ordinary use. The way to
accelerate is to run `manual` plus shadow ourselves, not to change the
default and bill everyone for our tuning.

## Verification

1344 tests, all passing. The floor carries one case per kind asserted
against a high-confidence allow, since that is the shape a successful
injection produces; the payload carries the assertions about what is kept
out, since prompt wording cannot restore it once something starts
including it.
