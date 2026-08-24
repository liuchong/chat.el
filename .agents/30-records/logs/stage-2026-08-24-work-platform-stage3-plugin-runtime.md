# Stage Log: Work Platform Stage 3 Plugin Runtime

- Type: stage-log
- Status: complete
- Scope: work-platform
- Date: 2026-08-24

## Summary

Stage 3 adds the scoped plugin and permission runtime. Plugins now carry
lifecycle state, record the services/tools/hooks they own, retry pending
dependencies, and roll back owned resources when stopped or when setup
fails. Tool exposure and direct execution now honor session overlays,
and tool events include owner, sensitivity, and effect metadata when
available.

## Changes

- Extended `chat-plugin` with pending, active, failed, and disposed
  lifecycle states.
- Added owner-scoped registration helpers for tools and hooks.
- Added reverse-order rollback for plugin-owned services, tools, and
  hooks.
- Marked Emacs plugin tools as project/read capabilities owned by the
  plugin runtime.
- Activated `chat-session-tool-config` for both provider-visible tools
  and direct tool execution.
- Added permission metadata to tool events for future shared approval
  surfaces.

## Verification

- Focused Stage 3 tests:
  `emacs -Q -batch -l tests/run-tests.el --eval '(ert-run-tests-batch "chat-\\(plugin\\|tool-caller\\|session\\)")'`
- Canonical suite:
  `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`

## Remaining Work

- Add durable session tree and branch metadata.
- Add compaction records and tool-pair-safe summaries.
- Detect interrupted assistant/tool pairs on reload without inventing
  successful results.
