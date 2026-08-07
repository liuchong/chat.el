# Deep Project Review 2026-08-07

- Type: logs
- Attention: records
- Status: final
- Scope: project
- Tags: review, security, quality, architecture

## Summary

Read-only deep review of the whole repository (no code changes).
Findings were cross-checked by four parallel read-only investigations
(core/llm, tools/patch, ui/code-mode, tests/docs/repo) plus manual
spot verification of the top severity items.

## Top Confirmed Findings

1. `lisp/llm/chat-llm.el:261` logs full request headers including
   `Authorization: Bearer <key>` to `~/.chat/chat.log` in cleartext.
2. `lisp/tools/chat-tool-shell.el:39-56` default whitelist includes
   `sed `, `awk `, `find ` which bypass approval and allow arbitrary
   command execution (`awk 'BEGIN{system(...)}'`) or deletion
   (`find -delete`) with no path validation.
3. `chat-tool-forge-load-all` evals every persisted tool under
   `~/.chat/tools/` at startup with no approval or integrity check.
4. `lisp/tools/chat-tool-caller.el:149-161` infinite loop on unclosed
   ```json fence; hangs the main loop until C-g.
5. `lisp/ui/chat-ui.el:871` broken regex `";\|&&\|||"` makes the
   `!cd` special case unreachable (empty trailing alternative matches
   everything). Manually verified.
6. Global (non buffer-local) request state in `chat-ui.el:39-49`
   breaks multi-session isolation; cancel in one buffer kills the
   request of another.
7. Unbounded diagnostics traces: `chat-request-diagnostics--traces`
   never pruned; per-chunk `append` makes streaming O(N^2).
8. `chat-files-encode` / `chat-files-backup` write to caller-supplied
   output paths without validation (sandbox escape).
9. chat-ui <-> chat-code massive duplication with drift; experimental
   modules (refactor/git/test/perf/intel/lsp) confirmed broken or
   unreachable in stable path.
10. Docs/repo drift: README claims 275 tests, PROJECT_STATUS 376,
    actual 429; `.agents/00-entry/current.md` 5 phases stale; one
    verified test stage in `tests/unit/test-chat-files.el` sits
    uncommitted.

## Notes

- Patch engine in `chat-files.el` is the strongest component
  (plan/commit, error families, drift tolerance) but the file is a
  1891-line god module due for a split.
- Test suite verified green: 429/429 passing in batch.
