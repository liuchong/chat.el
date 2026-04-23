# Focus

- Type: progress
- Attention: active
- Status: active
- Scope: current-stage
- Tags: focus, current, stage

## Doing Now

Ship user-visible execution UX stages on top of the new `.agents/` workflow without falling back to fragmented, opaque, or documentation-only approval handling.

## Not Doing Now

- No rollback to the legacy `docs/ai-contexts/` workflow
- No broad repository process changes outside `chat.el`
- No full visual redesign beyond the request-panel execution surface
- No attempt to replace Emacs-native approval input with a bespoke widget layer yet
- No async rewrite of the synchronous approval pipeline
- No transcript-level approval blocks that would pollute the main conversation body

## Immediate Next Step

Build the next UX stage on the new diagnostics baseline, using native Emacs prompts and status feedback to teach approval actions before users even open the panel.
