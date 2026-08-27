# Stage: MDP Two-View Preview

- Type: logs
- Attention: records
- Status: complete
- Scope: mdp-ui
- Tags: mdp, preview, ui, codec, markdown

Date: 2026-08-27
Spec: 006 (MDP payload support)

## The missing piece

The codec already exposed both operations needed to verify MDP: parse a
payload into typed Elisp values, and render those values as a machine view.
The Markdown renderer already supplied the human document view. There was no
interactive command that put the two readings together, so seeing the Lisp
side required evaluating internal functions by hand.

## What changed

`lisp/ui/chat-mdp-view.el` adds `M-x chat-mdp-preview-region`. It requires a
selected complete payload, then opens one read-only buffer containing:

- the source rendered as a Markdown document
- the parsed and explicitly typed machine view
- or, after a parse failure, the exact MDP error code and line number while
  leaving the document view visible

The module is deliberately in `ui`. `lisp/core/chat-mdp.el` remains a pure
codec with no buffer or window dependencies, and the UI reuses its machine
view rather than growing a second parser.

## Verification

Focused ERT tests distinguish the number `28` from the string `"28"`, assert
that parse errors remain visible, check the fixed-pitch machine face, and
verify that the preview entry point is an interactive command: 4/4 passed.
The complete suite passed 1364/1364 with zero unexpected results, including
the documentation check that every named `M-x` command exists.
