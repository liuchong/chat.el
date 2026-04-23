# Focus

- Type: progress
- Attention: active
- Status: active
- Scope: current-stage
- Tags: focus, current, stage

## Doing Now

Ship session-history workflows on top of the new `.agents/` baseline without letting resend and regenerate features diverge between chat mode and code mode.

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

Build the next session UX stage on the new replayable history baseline, with the next likely target being discoverable session commands or a richer session browser rather than ad hoc buffer mutations.
