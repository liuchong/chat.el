# Spec 025: Passive Slash Command Hints

- Status: accepted
- Scope: chat input surface
- Replaces: no existing command or message contract
- Depends on: Decision 0012, the canonical slash command table and chat i18n

## Problem

A developer typing a slash command needs to see which command names still match
the current prefix. A selectable completion UI is the wrong interaction: it owns
keyboard focus, gives `RET` a candidate-selection meaning, introduces a second
commit step and can move the chat window while the developer is typing.

The input surface instead needs a passive hint. It may show possible continuations,
but it must never become an interactive control.

## Interaction Contract

When point is at the end of a slash-command token that begins at the chat input
marker, the UI may render matching command names. `/s` may therefore show `/save`,
`/send` and `/stage`. The hint disappears when the token no longer denotes a
command prefix, point leaves its end, an argument separator or second slash is
entered, the input is cleared, or the command is submitted.

The hint has all of these invariants:

- it has no selected row, cursor, marker, active keymap or focus;
- Up, Down, mouse movement, `RET` and command dispatch never enter the hint;
- `RET` always keeps the existing chat send/dispatch meaning in one key press;
- it is rendered as restrained buffer text with no border, panel background or
  graphical selection treatment;
- it is display-only: it does not enter buffer text, kill/yank data, session
  storage, transcript, model context or input history;
- it is derived from the canonical command table and the current UI language,
  so the hint cannot advertise an unavailable command;
- at most `chat-ui-command-hint-limit` rows are visible, with a default of 8 and
  an allowed range of 1 through 10;
- the list appears below the input line when all visible rows fit there without
  scrolling the window; otherwise it appears above. When neither side fits the
  requested count, it uses the side with more room and truncates to that room;
- showing, updating and hiding it preserve point, input text and `window-start`.

## Ordering

`chat-ui-command-hint-sort-order` defaults to `alphabetical`. Names are compared
deterministically after case folding, with the original display name as the tie
breaker.

The optional value `frequency` uses successful command dispatch counts stored on
the current session. Higher counts come first; unseen commands and equal counts
fall back to the same alphabetical order. Usage affects display order only. It
cannot remove a candidate, change prefix matching or influence `TAB` completion.

## TAB Completion Contract

`TAB` is independent of the passive hint and never navigates it. It queries the
normal completion-at-point source for the current input token, then performs only
deterministic prefix expansion:

1. one candidate completes to that full candidate;
2. several candidates complete only through their longest common prefix;
3. no candidate, an exact input or no longer common prefix leaves the input
   unchanged;
4. `TAB` never starts a completion session, opens a menu, selects a row or changes
   the meaning of the next `RET`.

This contract applies equally when the active source is slash-command completion
or path completion. Candidate display remains a convenience; prefix completion
must work with the hint disabled.

## Architecture

The implementation is a buffer-local zero-width overlay owned by `chat-mode`.
One post-command observer computes a pure hint model containing prefix, ordered
candidates, annotations, direction and visible row count. A renderer projects
that model to `before-string` or `after-string`; cleanup deletes the overlay.

The observer must be bounded by the number of registered commands. It performs no
I/O, timer polling or model work. Session command-usage counters are updated only
after a known command handler has been invoked successfully.

## Non-Goals

- candidate selection, candidate focus or keyboard navigation;
- child frames, tooltips, minibuffers, menus or third-party completion frontends;
- fuzzy, semantic or substring matching;
- automatically inserting a candidate because it ranks first;
- changing slash parsing, unknown-command fallback, sticky command ownership,
  send modes or message staging.

## Acceptance

Automated tests must prove:

- `/` and a partial prefix show only matching canonical/current-language names;
- alphabetical and frequency ordering are deterministic and capped at 10;
- ties and unseen commands use lexical order;
- enough room selects below, insufficient room selects above, and constrained
  space truncates without moving point or `window-start`;
- moving point away, adding an argument, sending and clearing remove the overlay;
- the overlay adds no buffer characters and owns no keymap;
- `RET` dispatches exactly once while a hint is visible;
- `TAB` completes one candidate or a longest common prefix without opening a
  completion session;
- command and path completion still exclude each other at the slash/path boundary;
- command-table/help/i18n consistency and the full canonical suite remain green.

