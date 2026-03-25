# Documentation Index

This directory keeps project level status, troubleshooting notes, and AI session records.

## Read This First

- `../README.md` gives the main project overview and quick start
- `PROJECT_STATUS.md` gives the current implementation snapshot
- `troubleshooting-pitfalls.md` lists known issues and their fixes
- `../AGENTS.md` defines repository rules for AI and IDE agents

## AI Context Records

The `ai-contexts/` directory stores session level records.
Each record should explain:

- requirements
- technical decisions
- completed work
- pending work
- key code paths
- issues encountered
- verification results

See `ai-contexts/README.md` for the naming format and suggested template.

## Books

The `books/` directory stores comprehensive, systematic documentation.

Long-form content that covers a topic in depth:
- Architecture guides
- Design principles
- Complete feature specifications
- Development handbooks

## Articles

The `articles/` directory stores focused, medium-length writings.

Single-topic pieces that explore specific subjects:
- Technical deep dives
- Best practice guides
- Post-mortem analysis
- Implementation stories
- Tool comparisons

## Tips

The `tips/` directory stores short-form inspirations and quick notes.

Brief but valuable snippets:
- Code patterns worth remembering
- One-liners and quick fixes
- Tool tricks and hidden features
- Aha moments and insights
- Bookmark-worthy resources

## When To Update Which File

- Update `PROJECT_STATUS.md` when the project baseline changes in a meaningful way
- Update `troubleshooting-pitfalls.md` when you discover a new failure mode or fix pattern
- Add or update an `ai-contexts/conversation-YYYY-MM-DD-topic.md` file at the end of each development session
- Update `README.md` when setup, commands, architecture, or user visible capabilities change

## Troubleshooting Maintenance Rules

`troubleshooting-pitfalls.md` is a structured handbook rather than a running log.

- Add new entries under the closest topic section
- Keep the topic order stable
- Use the field order `Problem` `Cause` `Solution`
- Merge duplicates before adding new entries

## Current Documentation Layout

| File/Directory | Purpose |
|----------------|---------|
| `README.md` | Project overview and quick start |
| `PROJECT_STATUS.md` | Current state and next focus |
| `troubleshooting-pitfalls.md` | Known issues and fixes |
| `ai-contexts/README.md` | Rules for session documents |
| `ai-contexts/*.md` | Historical implementation records |
| `books/` | Long-form systematic documentation |
| `articles/` | Focused medium-length articles |
| `tips/` | Short-form inspirations and quick notes |
| `specs/` | Feature specifications and design documents |

## Test Directory Layout

| Directory | Purpose |
|-----------|---------|
| `tests/unit/` | Unit tests using ERT |
| `tests/integration/` | Integration tests |
| `tests/prototypes/` | Prototype tests for feasibility validation |
| `specs/` | Feature specifications and design specs |
