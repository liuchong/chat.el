# Focus

- Type: progress
- Attention: active
- Status: active
- Scope: current-stage
- Tags: focus, current, stage

## Doing Now

Keep the shared reading workflow stable while continuing to raise coverage around file-editing reliability, standard and codex newline-marker compatibility, unified-diff metadata compatibility, hunk validation, hunk-header validation, header-drift tolerance, empty-update rejection, replace success semantics, replace no-op semantics, patch net no-op semantics, line-scoped replace diagnostics, invalid-regexp diagnostics, empty-pattern validation, empty-match regexp refusal, directory-path validation across patch and non-patch editing flows, missing-target validation across direct edit flows including insert operations, direct-edit error semantics, patch application error prefix normalization, patch failure-family normalization, patch empty-file semantics, patch conflict semantics, chained patch path reliability, ambiguous line-hint handling, add-file validation, regexp narrowing behavior, move-only patch behavior, patch atomicity, pure insert and delete hunk compatibility, sequential hunk line-delta stability, update-patch EOF semantics, replace narrowing behavior, whitespace-aware context refusal behavior, command surfaces, multi-operation patch composition reliability, and nested patch path reliability.

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

Keep pushing test density around patch-engine and search-replace edge cases until patch net no-op refusal, replace no-op refusal, patch no-op refusal, add-existing conflicts, delete-missing conflicts, move-missing-source conflicts, chained move paths, add-then-delete cleanup, move-then-delete cleanup, empty add-file semantics, empty update results, nested add paths, nested move targets, nested add rollback behavior, ambiguous patch failures, invalid pure-insert locations, add, delete-plus-add replacement, add-then-update composition, move-then-update composition, move-then-recreate-source composition, pure insert, pure delete, sequential hunk drift, inaccurate header counts, directory-path misuse, missing edit targets, insert target misuse, update, move, move-only updates, metadata lines, malformed hunk payloads, malformed headers, invalid add-file payloads, empty updates, empty search text, empty-match regexps, replace-all success paths, expected-count success paths, invalid-regexp failure paths, line-scoped replace diagnostics, ambiguous line-hint paths, regexp line-filtered success paths, patch atomicity, standard newline markers, newline semantics, direct-edit error semantics, and patch application error normalization are no longer the easiest path to a production failure.
