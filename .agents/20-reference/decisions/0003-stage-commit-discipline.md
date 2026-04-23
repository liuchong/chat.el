# Decision 0003

- Type: decisions
- Attention: reference
- Status: accepted
- Scope: workflow
- Tags: commits, stages, verification

## Title

Each verified stage must be committed immediately

## Context

The repository now uses a stage-based workflow where code, tests, and knowledge records are advanced together. Allowing multiple completed stages to accumulate uncommitted makes rollback, handoff, and audit quality worse.

## Decision

- Treat `git commit` as the single allowed write-history git action
- Require one direct commit after each completed and verified stage
- Use the stage title format `feat: xxx test: yyy docs: zzz` with a detailed English body

## Consequences

- The worktree should rarely contain multiple already-validated stages at once
- Stage boundaries become visible in history
- Verification and knowledge-base updates must be finished before commit
