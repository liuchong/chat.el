# Documentation Workflow Correction

- Type: logs
- Attention: records
- Status: complete
- Scope: workflow
- Tags: docs, agents, cursor, cleanup

## Summary

Corrected stale documentation workflow guidance that had drifted back toward the legacy `docs/ai-contexts/` pattern and had started treating `docs/troubleshooting-pitfalls.md` as a routine session artifact again.

## Changes

- removed the new selector-conflict entry from `docs/troubleshooting-pitfalls.md`
- updated `.cursor/rules/documentation-maintenance.mdc` to point session records at `.agents/30-records/logs/`
- narrowed troubleshooting updates to user-facing durable pitfalls instead of ordinary stage notes

## Verification

- checked `git show HEAD` to confirm the latest commit introduced the unwanted troubleshooting entry
- searched the repository for `ai-contexts/` and `troubleshooting-pitfalls.md` references before applying the correction

## Remaining Gap

- other historical references to `docs/ai-contexts/` still exist in archived records and migration notes, but they are legacy references rather than active write targets
