# Risks

- Type: lessons
- Attention: active
- Status: active
- Scope: current-stage
- Tags: risks, workflow, migration

## Current Risks

- Old contributor habits may continue writing new records under `docs/ai-contexts/`
- Some older docs and readmes may still refer to `docs/ai-contexts/` until cleaned up
- Migrated legacy logs are heterogeneous and should not be treated as uniformly high-quality reference material

## Mitigations

- Keep `AGENTS.md`, `README.md`, and `.agents/README.md` aligned on the new read and write rules
- Use `20-reference/` for extracted stable knowledge rather than treating imported logs as stable truth
- Keep future stage summaries in `.agents/30-records/` so the new path becomes habitual
