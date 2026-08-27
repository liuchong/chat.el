# Stage: The Guard Can Think

Date: 2026-08-27
Spec: 013 (guard model approval)

## What was wrong

The guard offered a verdict tool and forced it with
`tool_choice: required`. That looked stricter, but some thinking models
support tools only through `auto` and reject the forced choice before they
can return a verdict. Since the guard correctly fails closed, configuring
one of those models turned every request failure into a refusal.

The environment payload had a separate identity bug. Its working directory
came from the session being judged, but its project root came from the
buffer-local current session. A callback running in another buffer could
therefore omit the root or describe the wrong project to the guard.

## What was checked

A credential-dependent probe against the configured DeepSeek endpoint
confirmed the boundary rather than assuming it from documentation:

- `deepseek-v4-flash`, thinking enabled, tools plus `auto` returned complete
  tool verdicts for both an allowed read and a denied force push.
- The same model with `required` returned HTTP 400 because thinking mode did
  not support that tool choice.
- A follow-up tool turn currently succeeded both with and without
  `reasoning_content`. The provider is lenient today, but its documented
  continuation contract still makes preserving that field a separate
  protocol stage rather than part of this guard fix.

## What changed

The guard now uses `tool_choice: auto`. Structure is still a hard boundary:
only a parsed `allow` with high confidence and a non-empty matched rule can
grant authority. Prose, malformed JSON, missing fields and request failures
still refuse.

`chat-tool-caller--code-project-root` now accepts an optional session. An
explicit session outranks the current tool execution and buffer sessions,
and both the guard environment and execution-directory fallback pass the
session they are actually handling.

Regression tests cover the portable request option and the case where the
current buffer and the judged session belong to different project roots.

Validation: 90 focused guard and tool-caller tests passed, followed by the
canonical suite at 1345/1345.
