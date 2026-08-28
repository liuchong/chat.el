# Chat Runtime and UI Reliability

- Type: record
- Attention: reference
- Status: complete
- Scope: chat-runtime-ui
- Tags: streaming, permission, scrolling, prompt, roles, cancellation, markdown

## Reported Failures

Seven failures were reproduced from normal chat use: an old run could end with
only a Thinking projection, a denied write could be hidden by a confident final
answer, live output moved a manually scrolled window, role colours disappeared,
the input prompt disappeared while its text remained editable, `C-c C-c` could
not stop a run, and emphasis beside Chinese punctuation remained raw during a
long streaming tail.

## Runtime Rules

- A provider completion closes a reasoning-only stream exactly once even when
  final content is empty. The terminal event is a runtime fact, not inferred
  from whether visible prose exists.
- The latest permission-denied tool event is rendered as an explicit error
  trailer. A later assistant sentence cannot overwrite or conceal it.
- `C-g` and `C-c C-c` both cancel the active Agent run. The fallback also
  cancels a direct request or stream and closes request diagnostics.

## Window and Presentation Rules

- Window intent is captured before each live redraw. Only a window exactly at
  the previous buffer end follows output. Every manually scrolled window
  restores markers for its historical top line and point after the redraw.
- A manually scrolled window remains fixed even when point is still in the
  off-screen input area. The input cursor does not reclaim or recenter that
  window; following resumes only after the reader returns to the live edge.
- Role labels retain a semantic `chat-ui-role` property independently of their
  face. Live and full redraws repair role faces and the input prompt from
  semantic markers. A bounded post-command repair also restores the prompt and
  only the role labels visible after navigation, avoiding a full-history scan.
- Cancellation keys are rebound outside the mode-map initializer as well as
  declared in it. Reloading the package in a long-running Emacs therefore
  updates an already-existing keymap instead of leaving `C-c C-c` undefined.

## Markdown Rule

The bounded streaming fallback still skips expensive block layout for a very
long unfinished tail, but now runs the linear inline renderer. Emphasis such as
`**现状诊断**：` therefore hides its markers and keeps its face before the
block closes. The completed block still uses the full renderer. Table parsing,
visible-width measurement, fixed-pitch cells and column alignment were not
changed.

## Verification

- canonical unit suite: 1777/1777 passed, zero skipped and zero unexpected
- deterministic integration: 2/2 passed; two credentialed provider checks
  skipped explicitly because credentials are absent
- deterministic end-to-end: 2/2 passed
- built-in offline Eval: 5/5 passed
- dedicated regressions cover reasoning-only completion, visible permission
  denial, both cancellation keys, prompt repair, semantic role-face repair,
  exact-edge following, a real manually scrolled window and long-tail CJK
  emphasis
- the existing Markdown table and 1,000-update UI stability suites remain green
- the Darwin compiler-isolation capability test gives cold compiler and dynamic
  linker startup a 10-second test budget while retaining strict status and
  executable-artifact assertions; product timeout defaults are unchanged
- source parenthesis checks and `git diff --check` pass

## Lessons

- Capture user viewport intent before mutation; post-render proximity is not
  evidence that the user wanted to follow.
- Point and viewport are separate state. Keeping an input point visible after
  the reader scrolls into history violates the stronger viewport intent.
- Persist semantic display identity separately from faces, then repair faces
  idempotently after redraws and navigation.
- A `defvar` initializer does not update an existing keymap during package
  reload. Emergency bindings also need an idempotent top-level definition.
- Permission outcomes belong to the transcript even when the model summarizes
  them incorrectly.
- A performance fallback may reduce layout work, but it must preserve the
  common inline syntax users can already see arriving.
