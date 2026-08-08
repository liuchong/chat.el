# Focus

- Type: progress
- Attention: active
- Status: active
- Scope: current-stage
- Tags: focus, current, stage

## Doing Now

The unified agent kernel plan (phases 1-8) is complete. Plain chat
and code mode both run on `lisp/core/chat-agent.el`; shell execution
is async with timeout and output spill; replace matching has a fuzzy
cascade; diffs are real unified hunks; sessions are append-only
JSONL with memory.md support; AGENTS.md discovery stacks ancestors;
streaming renders are differential with markdown-lite styling.
493 tests passing.

## Not Doing Now

- No rollback to the legacy `docs/ai-contexts/` workflow
- No parallel tool execution (interactive approval requires serial)
- No session tree branching
- No security hardening passes unless they block a functional stage

## Immediate Next Step

Real world usage validation of the new kernel path, then parity for
the code-mode render path (differential render plus markdown-lite),
and collapsible tool event blocks. Deferred security items from the
deep review (log redaction, shell whitelist tightening, forge load
checks, encode/backup output validation) can be scheduled when the
user asks.
