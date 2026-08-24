# Stage Log: Work Platform Stage 12 Session Runtime

- Type: logs
- Attention: records
- Status: complete
- Scope: sessions, branching, compaction, recovery
- Tags: jsonl, branches, summaries, recovery

## Summary

This stage closes the durable session gaps found by the execution audit:
non-destructive branching, persistent context compaction, atomic updates,
and actionable interrupted-run recovery.

## Changes

- Create child sessions at message boundaries for regenerate/edit-resend.
- Preserve original histories and record child ids on branch-point
  messages.
- Rebuild chat and code surfaces from the new active branch.
- Persist summary coverage through message ids and reuse the latest
  summary on subsequent requests.
- Run automatic iterative compaction before every over-budget agent step.
- Keep compaction cut points outside open assistant/tool pairs.
- Add asynchronous model-based manual compaction with deterministic
  automatic fallback.
- Replace in-place JSONL append with same-directory temporary write plus
  atomic rename.
- Normalize message metadata to a JSON object for reliable tool-call ids.
- Add explicit interrupted-run actions: mark failed, discard, or keep.
- Expose recovery from the session-tree UI.

## Verification

- Canonical command:
  `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- Result:
  `Ran 575 tests, 575 results as expected, 0 unexpected`

## Remaining Work

- Execute and resume declarative workflows instead of storing records only.
- Notify users when background work completes or fails.
