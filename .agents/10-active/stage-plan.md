# Stage Plan

- Type: progress
- Attention: active
- Status: active
- Scope: planning
- Tags: stage, plan, migration

## Goal

Finish the migration from `docs/ai-contexts/` to `.agents/` and make the new workflow the only formal agent path.

## Completed

- Created `.agents/` entry, active, reference, records, templates, and workspaces structure
- Migrated legacy session records into `.agents/30-records/logs/`
- Migrated the old implementation summary into `.agents/30-records/history/`
- Updated `AGENTS.md` to require the new read order and stage commit workflow

## Tests

- Human verification of migrated file layout
- Final repository verification should still use `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`

## Remaining

- Keep future stage records in `.agents/`
- Clean residual human-facing references that still mention `docs/ai-contexts/` when they are next touched

## Risks

- Stale documentation references may confuse contributors
- Imported logs still need selective distillation into stable knowledge

## Next Entry

Record the next functional implementation stage in `.agents/30-records/` and promote any durable findings into `20-reference/`.
