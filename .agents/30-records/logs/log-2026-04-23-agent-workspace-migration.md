# Log Item

- Type: logs
- Attention: records
- Status: completed
- Scope: workflow-migration
- Tags: migration, agents, docs, logs

## Summary

- Adopted the `coreutils.zig`-style `.agents/` workspace model in `chat.el`
- Migrated legacy `docs/ai-contexts/` records into `.agents/30-records/logs/`
- Promoted stable workflow and implementation knowledge into `20-reference/`
- Repointed `AGENTS.md`, contributor notes, and the legacy `docs/ai-contexts/README.md` to the new workflow

## Verification

- Verified the `.agents/` directory layout and imported records
- Kept the canonical runtime verification path as `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
