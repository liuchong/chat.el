# Knowledge Item

- Type: knowledge
- Attention: reference
- Status: active
- Scope: code-mode
- Tags: code-mode, tools, json, editing

## Problem

Code mode drifts when it invents its own tool protocol, prompt rules, or tool result rendering path instead of reusing the shared tool-calling core.

## Symptoms

- Code mode renders raw tool JSON to the user
- Approval behavior differs between chat and code mode
- Tool follow-up loops diverge and regress independently

## Resolution

- Reuse the shared JSON tool-calling prompt contract
- Route code mode response finalization through the same processed tool result model
- Keep code-mode-specific guidance limited to guardrails, editing protocol, and project-root context

## Regression Guard

- Maintain unit tests for code mode prompt shape, tool follow-up, and access-root behavior
- Add regressions when code mode and chat mode behavior diverge
