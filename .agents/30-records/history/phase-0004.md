# Phase 0004

- Type: progress
- Attention: records
- Status: completed
- Scope: agent-workspace-migration
- Tags: phase, agents, migration, workflow

## Goal

Adopt the `coreutils.zig`-style agent knowledge base model in `chat.el` and migrate the accumulated workflow records into it.

## Completed

- Created the `.agents/` directory with entry, active, reference, records, templates, and workspaces layers
- Migrated legacy `docs/ai-contexts/` session records into `.agents/30-records/logs/`
- Migrated the old implementation summary into `.agents/30-records/history/`
- Updated `AGENTS.md` to require the new read order and stage commit discipline
- Updated human-facing readmes to point contributors at `.agents/`

## Tests

- Structural verification of the migrated knowledge base
- Runtime regression verification should continue through `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`

## Remaining

- Continue distilling imported logs into cleaner long-term reference knowledge
- Remove residual stale references when touched in later stages

## Risks

- Contributors may still instinctively look for `docs/ai-contexts/`
- Imported logs preserve historical inconsistency and should be treated as raw records

## Next Entry

Record the next product implementation stage directly under `.agents/30-records/`.
