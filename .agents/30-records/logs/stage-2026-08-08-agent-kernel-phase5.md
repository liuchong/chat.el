# Stage Log 2026-08-08 Agent Kernel Phase 5 (edit robustness and diff)

- Type: logs
- Attention: records
- Status: final
- Scope: project
- Tags: stage, editing, diff, preview

## Summary

Phase 5 of the unified agent kernel plan: fuzzy replace matching,
inline edit safety, and real unified diffs. Suite: 476 tests, 476
passing.

## What Landed

- Replace cascade in `files_replace` (pi/opencode inspired): when an
  exact literal match fails, matching degrades through line-based
  levels — trailing whitespace, Unicode punctuation folds (smart
  quotes, dashes, ellipsis, exotic spaces, BOM), then indentation.
  The first level with candidates wins; ambiguity and selector rules
  are unchanged. Fuzzy replacements preserve the file line ending
  style (CRLF vs LF) inside the replaced block, and the tool result
  reports `:match-mode` when it was not exact.
- `chat-edit--write-content` validates target paths through
  `chat-files--safe-path-p`, so inline edits honor the same allowed
  directories as the file tools.
- `chat-edit--refresh-file-buffer` no longer reverts buffers with
  unsaved user modifications.
- New built in unified diff (`chat-files--unified-diff`): LCS edit
  script with a size guard, hunk grouping with 3 context lines, git
  style headers. `chat-files--diff-strings` and the code preview
  fallback use it when the external diff command is missing,
  replacing the bogus `@@ -1,1 +1,1 @@` placeholder.
- Preview fixes: change navigation regex no longer lands on +++/---
  headers, and the manual edit flow now has working C-c C-c confirm
  and C-c C-k cancel bindings that refresh the preview.

## Test Changes

- 7 cascade tests (trailing whitespace, unicode folds, indentation,
  CRLF preservation, ambiguity refusal, no-match refusal, exact
  stays exact).
- New tests/unit/test-chat-edit.el (4 tests: allowed write, outside
  rejection, modified buffer kept, clean buffer reverted).
- New tests/unit/test-chat-code-preview.el (8 tests: real hunks,
  pure addition/deletion headers, identical inputs, distant hunks,
  no-external-diff fallback, preview fallback, nav regex).

## Verification

- `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
  reports 476 results as expected, 0 unexpected.

## Not Done

- Phases 6-8: session JSONL and memory file, AGENTS.md ancestor
  stacking, UI rendering.
- The fuzzy cascade replaces the matched block verbatim with the new
  text; pi's preserve-unchanged-lines writeback is a possible later
  refinement.
