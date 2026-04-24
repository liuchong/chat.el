# Current

- Type: progress
- Attention: entry
- Status: active
- Scope: project
- Tags: current, phase, migration

## Current Phase

Phase 0057 patch empty file semantics stage is complete.

## Main Objective

Keep `chat.el` on the new `.agents/` workflow while improving shared reading capture guardrails, unidiff compatibility, and file-editing reliability under AI-generated patch and search-replace inputs, especially around production-grade patch semantics, newline-marker compatibility, unified-diff metadata compatibility, hunk validation, hunk-header validation, header-drift tolerance, empty-update rejection, replace success semantics, invalid-regexp diagnostics, empty-pattern validation, empty-match regexp refusal, directory-path validation across patch and non-patch editing flows, missing-target validation across direct edit flows including insert operations, direct-edit error semantics, patch application error prefix normalization, patch failure-family normalization, patch empty-file semantics, ambiguous line-hint handling, add-file validation, regexp narrowing behavior, move-only patch behavior, patch atomicity, hunk coverage, sequential hunk stability, multi-operation patch composition reliability, and nested patch path reliability.

## Active Modules

- `AGENTS.md`
- `.agents/`
- `lisp/`
- `tests/`
- `docs/troubleshooting-pitfalls.md`

## Recommended Reads

- `../10-active/focus.md`
- `../10-active/risks.md`
- `../20-reference/decisions/0001-agent-knowledge-layout.md`
- `../20-reference/decisions/0002-json-structured-protocols.md`
- `../20-reference/knowledge/request-diagnostics-lifecycle.md`
