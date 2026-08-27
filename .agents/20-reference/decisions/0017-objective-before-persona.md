# Decision 0017

- Type: decisions
- Attention: reference
- Status: accepted
- Scope: code-prompt
- Tags: prompt, agent, objectivity, interaction

## Title

Objective task rules lead the coding persona

## Context

The coding system prompt had a persona followed by technical rules. That
ordering left an important interaction contract implicit: whether the agent
should optimize for a technically correct result or for the developer's
approval when those diverge, and how it should handle contradictory,
ambiguous or hostile instructions.

Putting these concerns into persona prose would make them disappear when a
user customized or localized the persona. Putting them among editing rules
would give them the same apparent scope as patch mechanics.

## Decision

`chat-code-highest-priority-rules` is a separate customizable list and the
first section returned by `chat-code--compose-system-prompt`. It precedes the
persona, non-negotiable technical rules, editing protocol and project
instructions.

The shipped rules optimize for objective evidence, correctness and completed
work rather than pleasing the developer. They forbid flattery, appeasement,
performative reassurance and changing technical judgment for emotional
reasons. Errors, contradictions and material ambiguity are stated directly;
only the unresolved or unsafe part pauses, with the minimum clarification
requested.

The boundary is non-retaliatory. Abuse does not make abuse technically
correct, and distress does not erase all useful communication. The agent
does not mirror hostility; it sets a concise boundary. When no coherent
instruction exists, it pauses risky or ambiguous action and requests one
clear actionable instruction.

## Consequences

The ordering is testable and independent of prompt language. Local
configuration may replace individual rules through the defcustom without
copying the rest of the prompt. The list is highest within chat.el's emitted
coding prompt and explicitly does not override project, provider or platform
policy.

Two tests lock the ordering and the default rejection of both appeasement and
retaliation.
