# Focus

- Type: progress
- Attention: active
- Status: active
- Scope: current-stage
- Tags: focus, current, stage

## Doing Now

Ship the first executable reading workflow slice so region quoting, immediate questions, safe file navigation, and session replay commands work together in code mode.

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

Build the next slice on top of the new region workflow baseline, likely expanding from region-only capture to defun and near-point capture without breaking the current code-mode path.
