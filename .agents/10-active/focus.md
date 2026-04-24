# Focus

- Type: progress
- Attention: active
- Status: active
- Scope: current-stage
- Tags: focus, current, stage

## Doing Now

Keep the shared reading workflow stable while continuing to raise coverage around file-editing reliability, standard and codex newline-marker compatibility, unified-diff metadata compatibility, hunk validation, hunk-header validation, empty-update rejection, replace success semantics, patch atomicity, pure insert and delete hunk compatibility, sequential hunk line-delta stability, update-patch EOF semantics, replace narrowing behavior, whitespace-aware context refusal behavior, and command surfaces.

## Not Doing Now

- No rollback to the legacy `docs/ai-contexts/` workflow
- No broad repository process changes outside `chat.el`
- No full visual redesign beyond the request-panel execution surface
- No attempt to replace Emacs-native approval input with a bespoke widget layer yet
- No async rewrite of the synchronous approval pipeline
- No transcript-level approval blocks that would pollute the main conversation body
- No widget-heavy panel controls that would fight normal Emacs buffer usage
- No promotion of ordinary tool activity into persistent status surfaces

## Immediate Next Step

Keep pushing test density around patch-engine and search-replace edge cases until add, pure insert, pure delete, sequential hunk drift, update, move, metadata lines, malformed hunk payloads, malformed headers, empty updates, replace-all success paths, expected-count success paths, patch atomicity, standard newline markers, and newline semantics are no longer the easiest path to a production failure.
