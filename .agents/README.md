# Agent Workspace

This hidden directory is part of the tracked project source of truth.

- Do not ignore `.agents/` because it is hidden.
- Every agent must read the required entry files here before implementation work.
- User-facing project documentation belongs in `docs/`, not in `.agents/`.

## Model

This workspace uses two independent dimensions.

### Attention Levels

- `00-entry` contains the smallest required entry context
- `10-active` contains current hot working context
- `20-reference` contains stable reusable reference knowledge
- `30-records` contains low-frequency records for lookup and audit

### Knowledge Types

- `decisions` records durable design decisions
- `knowledge` records reusable implementation facts
- `lessons` records mistakes and caution notes
- `logs` records work and investigation traces
- `compatibility` records version and platform differences
- `progress` records stage progress and handoff state

## Required Read Order

1. `../AGENTS.md`
2. `README.md`
3. `00-entry/current.md`
4. `00-entry/read-order.md`
5. `10-active/focus.md`
6. `10-active/risks.md`
7. Task-specific files only after the above

Do not scan the whole `.agents/` directory by default.

## Write Rules

- Shared layers are `00-entry`, `10-active`, `20-reference`, and `30-records`
- Parallel agents must write private notes under `workspaces/<agent-id>/`
- Only the integrating agent should merge stable results back into shared layers
- All formal records in this directory must be committed to git

## Metadata

Formal records should include these fields near the top:

- `Type`
- `Attention`
- `Status`
- `Scope`
- `Tags`

## Relationship To Legacy Records

- Historical `docs/ai-contexts/` records were migrated into `30-records/logs/`
- New agent records must not be added under `docs/ai-contexts/`
- `docs/troubleshooting-pitfalls.md` remains the human-facing pitfall handbook
