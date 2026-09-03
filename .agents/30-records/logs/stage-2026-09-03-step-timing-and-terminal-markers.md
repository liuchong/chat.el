# Step Timing, Terminal Markers and Send-Path Phase Guard

- Type: stage-record
- Attention: active
- Status: implementation-verified
- Scope: transcript rendering, runtime status, request diagnostics
- Date: 2026-09-03
- Spec: specs/004-live-turn-rendering-and-input-history.md（已补充对应章节）

## Driver

A frozen send earlier that day left "Preparing stream request" as the only
clue; everything between the keystroke and the wire was one opaque gap.  The
transcript also never said what a step cost or how a run ended: a finished
run and a stalled one looked identical from the status line.

## Contracts

- Fold rows carry their run's wall time (previous part's timestamp to the
  run's last), rendered as a `· 4.2s` suffix.  The first run has no
  predecessor and shows none.
- Every run ends with a persisted `turn-outcome` message: terminal state,
  total duration from request creation, step count.  The category is
  display-only (never sent to the model) and never folds.  The status line
  shows the outcome while idle and clears it when the next request begins.
- The live narrative line carries the elapsed seconds of the phase in
  flight, so a phase that stops advancing reads as a freeze without opening
  the request panel.
- The send path records each preparation phase into the request trace as it
  passes (context and tool prompt preparation, agent-run dispatch).  A Lisp
  spin blocks timers, so a watchdog cannot report from inside one; the
  durable trace pointing at the last completed phase is the whole guard.

## Verification

- New ert coverage: duration formatting, per-run fold-row duration, the
  first run's missing duration, and turn-outcome never folding nor feeding
  the model.  Four existing tests were updated to the new record shape
  (trailing terminal marker, phase-named waiting line).
- Full suite: 2061 passed, 0 unexpected.
