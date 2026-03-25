# AI Context Records

This directory stores development session records for `chat.el`.

## File Naming

Use this format:

```text
conversation-YYYY-MM-DD-topic.md
```

Examples:

- `conversation-2026-03-25-stability-repair.md`
- `conversation-2026-03-25-docs-refresh.md`

## Required Sections

Each record should include these sections:

```markdown
# Short Title

## Requirements

## Technical Decisions

## Completed Work

## Pending Work

## Key Code Paths

## Verification

## Issues Encountered
```

## Writing Rules

- Write for the next engineer or agent who has no context
- Keep statements concrete and factual
- Record the why behind important decisions
- Prefer short sentences
- Reference files by path when possible
- If there were no new pitfalls, say so explicitly

## Relationship To Other Docs

- Add durable failure patterns to `../troubleshooting-pitfalls.md`
- Update `../PROJECT_STATUS.md` if the overall project baseline changed
- Update `../../README.md` if setup or user visible behavior changed

## Minimal Example

```markdown
# Stability Repair

## Requirements

Close the remaining high risk review findings.

## Technical Decisions

Use real path resolution for file safety checks.
Require approval for AI generated tools.

## Completed Work

Updated `chat-files.el` and `chat-tool-forge-ai.el`.

## Pending Work

No remaining tasks in this phase.

## Key Code Paths

`chat-files.el`
`chat-tool-forge-ai.el`

## Verification

Ran `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`.

## Issues Encountered

No new pitfalls in this session.
```
