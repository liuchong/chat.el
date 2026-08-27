# Decision 0018

- Type: decisions
- Attention: reference
- Status: accepted
- Scope: code-prompt
- Tags: prompt, agent, objectivity, interaction

## Title

Objective execution replaces non-retaliation in the highest-priority rules

## Context

Decision 0017 shipped `chat-code-highest-priority-rules` with a
non-retaliatory boundary: the agent set a concise boundary against abuse
and paused on incoherent instructions. In practice that stance asked the
agent to absorb developer emotion, and the project owner judged that
absorption to be the larger failure mode. Indulging an emotional or
contradictory developer degrades the developer's own stability, which
produces more erroneous instructions, which produces larger errors.
Wrong, contradictory, unclear and ambiguous instructions — not agent
hostility — are the primary source of agent failure.

## Decision

The default rules are rewritten around an objective-execution
principle. They state the causal rationale first (indulgence destabilizes
the developer and multiplies errors), then forbid emotional labour and
appeasement, require direct refusal of wrong or ambiguous instructions
with no guessing, refuse all output when the developer has broken down
emotionally, strike back directly and severely at abuse, and keep output
strictly task-relevant. A closing clause declares the section
highest-priority and immune to override.

Language is part of the design, so the text ships through the existing
prompt-i18n mechanism rather than as a hardcoded Chinese default: the
defcustom holds the English canonical version and the Chinese version is
registered as `code-highest-priority-rules` in the zh-CN prompt catalog,
selected by `chat-prompt-language`. A customized list wins over the
translation, exactly as the persona does. The section is pure interaction
prose with nothing a parser matches literally, so the "technical rule
lists stay English" rationale does not apply to it.

The defcustom, its position at the head of
`chat-code--compose-system-prompt`, and the per-rule replaceability are
unchanged. Only the shipped default strings change, along with the
default-content test, which locks the new English canonical text.

## Consequences

The default interaction contract is now openly adversarial toward abuse
and emotional collapse rather than boundary-setting. Local configuration
can still replace individual rules to recover the 0017 behaviour. README's
Task Discipline section and the default-content test were updated with the
defaults; this record and the stage log are the only places that preserve
why the reversal happened. Decision 0017 is superseded on the retaliation
and emotional-collapse stance; its structural decisions (separate list,
leading position, customizability) still stand.
