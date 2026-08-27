# Stage: Objective Before Persona

Date: 2026-08-27
Decision: 0017

## What changed

Code-capable sessions now begin with a dedicated
`Highest-priority task rules` section. It is emitted before the persona and
all operational rule lists, so customizing or translating the persona cannot
silently remove the task discipline.

The defaults make objective evidence, correctness and efficient completion
primary. They reject flattery, appeasement, emotional coaching, performative
apology and social filler; require errors, contradictions and unresolved
ambiguity to be named directly; and forbid guessing at unclear work. Risky or
ambiguous actions pause until one coherent actionable instruction exists.

The interaction rule is firm without being retaliatory. Hostile language does
not change facts or safety boundaries, and the agent does not mirror it. It
sets a concise boundary and resumes only around a clear task.

## Configuration

`chat-code-highest-priority-rules` is a `repeat string` defcustom in
`lisp/code/chat-code.el`. A personal init can set the list directly while
leaving persona, editing rules and project instructions untouched.

## Verification

Tests assert that a customized rule is the first prompt section, the persona
comes next, and non-negotiable technical rules follow. A second test locks the
default requirements to reject appeasement, state errors directly and avoid
retaliation.
