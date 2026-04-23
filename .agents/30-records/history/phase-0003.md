# Phase 0003

- Type: progress
- Attention: records
- Status: completed
- Scope: code-mode-hardening
- Tags: phase, code-mode, providers, structure

## Goal

Turn `chat.el` into a usable coding assistant inside Emacs with stronger repository structure, provider support, and code-mode behavior.

## Completed

- Reorganized runtime modules under `lisp/`
- Added multi-provider support and config loading
- Hardened code mode prompt rules, tool-calling contract, project-root behavior, and status UI
- Added real editing tools, richer approvals, structured tool feedback, and request diagnostics

## Tests

- Canonical suite reached the current 183-test baseline with 181 passing and 2 skipped provider tests

## Remaining

- richer timeline UI
- persistent approval preferences
- stronger spike coverage for prompt-to-edit protocols

## Risks

- Legacy agent knowledge was still split between `docs/ai-contexts/` and the rest of the repository

## Next Entry

Migrate agent workflow and history into a dedicated `.agents/` knowledge base.
