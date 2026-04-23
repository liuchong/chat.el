# Decision 0001

- Type: decisions
- Attention: reference
- Status: accepted
- Scope: agent-workspace
- Tags: agents, structure, workflow

## Title

Separate human documentation from agent development knowledge

## Context

`chat.el` accumulated workflow records, migration notes, and engineering investigation logs under `docs/ai-contexts/`. That mixed agent-specific development context with human-facing repository documentation and made onboarding ambiguous.

## Decision

- Keep `docs/` exclusively for user-facing or contributor-facing human documentation
- Keep stable hard rules in `AGENTS.md`
- Store persistent agent context in the tracked hidden directory `.agents/`
- Require every agent to read `.agents/` explicitly before implementation work

## Consequences

- Human documentation stays readable without internal workflow noise
- Agent context becomes persistent, versioned, and queryable by attention layer
- Legacy `docs/ai-contexts/` material must be migrated and no longer extended
