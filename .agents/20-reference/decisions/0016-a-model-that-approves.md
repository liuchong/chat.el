# Decision 0016

- Type: decisions
- Attention: reference
- Status: accepted
- Scope: approval
- Tags: approval, guarded, guard-model, shadow, security, tool-calling

## Title

A model does the approving, its refusal is survivable, and a floor sits
under it

## Context

Spec 012 gave permission one name and three modes: `manual`, `auto`,
`dangerous`. The middle one was reported as not being what its name said.
It was: fast path for grants, then a fixed rule list, then refuse without
asking. Nothing about it decided anything — it was `manual` with the
question suppressed, which is strictly worse than `manual` for the user
(they lose the ability to say yes) and no better for safety.

The name was the load-bearing part of the complaint. "Auto" reads as "it
handles it", so a user who wanted the assistant to get on with reading
files turned it on and got a mode that silently refused more than the one
they left. What was wanted is an approver: something that looks at the call
and rules on it, the way a person would, at the speed a model can.

## Decision

Four things, and the order matters because each one exists to make the next
affordable.

**The mode is called `guarded`.** `auto` is kept as an alias in every
reading path — the command, the customization, sessions on disk — and
nothing writes it any more. A mode name is documentation that cannot be
skipped, and this one was describing the wrong mechanism.

**A model rules on the call, and its verdict is worth what a person's is.**
Under `guarded`, a call that reaches the mode branch produces one neutral
request against a dedicated system prompt, and the answer is consent of
kind `guard`. `chat-approval-command-consent-p` returns true for it exactly
as for `human`, which means the tool's own gate does not run again. That is
deliberate and it is the whole mechanism: the gate's objection is handed to
the guard as evidence, so a gate that then refuses regardless makes the
verdict decoration. It is also the failure a person's approval used to hit —
read the command, approve it, be told the program is not on a list.

**A refusal is a tool result, not a fault.** It goes back through the
success path with the guard's reason, saying the policy refused rather than
the user, and naming that another approach is allowed. Through the error
path the loop would read it as the tool breaking. Nothing stops; the run
decides what to do about it. This is the difference between a policy the
assistant can work around and one it loops against, which is where the
eight-minute git incident came from.

**A floor sits underneath, and no verdict moves it.**
`chat-approval-guard-never-allow-p` is a predicate evaluated before any
request: writes outside `chat-files-allowed-directories`, deleting a home
or a project root, rewriting published history, a credential and the
network in one command, and edits to the approval records themselves. It
costs no model call and it is not a rule the guard weighs, because the
price of treating a verdict as a person's approval is that a wrong verdict
skips the gate. The floor is what makes that price bounded.

Two supporting choices:

**Structured output, and failure is refusal.** An allow requires
`decision: allow`, `confidence: high` and a non-empty `matched-rule`.
Prose, bad JSON, an abstain, a hedge, a timeout, a missing provider — all
refuse. The verdict tool is offered with `tool_choice: auto`: thinking
models may reject a forced call, while validation makes a prose response a
refusal rather than authority. A guard that fails open is not one.

**Denials are remembered for the session, allowances never are.** The key
is the exact arguments, so a refused call repeated verbatim costs nothing
and one changed character is a new question. An allowance that outlived its
request would be a grant, and grants are something a person makes on
purpose.

## Alternatives

**Let the executing model declare its own calls safe** (cline's shape).
Rejected: the thing being checked cannot be the thing checking, and
argument text is attacker-controlled input.

**Keep extending the static rules** (codex's shape, taken to its end).
Not rejected — it is what `guarded` falls back to when no guard is
configured, and what the floor is made of. It is insufficient as the whole
answer for the reason the report gave: the interesting cases are the ones
a list cannot enumerate, and every enumeration attempt grew the list
without closing it.

**Have the guard rule inside the run's own request.** Rejected: history
would come with it, and a guard carrying the run's history stops answering
"is this within policy" and starts answering "does the assistant want
this".

## Consequences

`guarded` now costs money and latency on calls that reach the mode branch,
which is why the fast path is ahead of the branch rather than inside it:
grants, tools needing no approval, and gate-approved commands are settled
without a request.

Synchronous authorization cannot consult the guard, and does not pretend
to. `chat-tool-caller-execute` refuses under `guarded` when a guard is
available, saying so, rather than silently applying the fallback rules the
guard exists to replace. Live execution goes through
`chat-approval-authorize-async`, which is now the only place any tool is
authorized — previously the two execution paths authorized separately, so a
grant applied or did not depending on whether a tool declared an
`async-function`.

Shadow running exists and ships off. It runs the guard alongside whatever
mode is in force, records the verdict against what actually happened, and
changes nothing. Its purpose is the one thing prompt work needs and cannot
get from reasoning about prompts: paired samples. Default-off is a choice
with a stated cost, recorded in the spec — the samples will come only from
people who turn it on, who may not represent ordinary use, and the way to
accelerate that is to run `manual` plus shadow ourselves rather than to
change the default and bill everyone for our tuning.

## Verification

1344 tests. The two groups carrying the weight are the floor — every kind
of refusal asserted to hold against a confident allow, since that is the
shape a successful injection produces — and the request payload, because
what is kept out of it cannot be restored by prompt wording once something
starts including it.
