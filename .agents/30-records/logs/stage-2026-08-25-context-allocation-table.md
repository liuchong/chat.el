# Stage 2026-08-25 - Per-category context allocation

## Goal

The context budget knew a total but not a composition, so it could say a
window was filling without saying by what. Divide usable context per
category, and give each category the overflow policy that actually applies
to it.

## The design question

Not the sizes. The sizes are calibration and can be tuned. What decides the
structure is that the categories differ in what can be done when one
overflows, and a single policy would be wrong for most of them:

- `demote` for declared resident text: honour what fits, move the excess to
  compactable, in document order.
- `compact` for history and project notes: a condensed record still helps.
- `trim` for file excerpts: they can be read again, so they are the cheapest
  thing to drop.
- `warn` for tool schemas: dropping a definition does not produce a context
  that fits, it produces a call that fails at the provider with no trace of
  why. So report and change nothing; the remedy belongs to whoever enabled
  the tools.

## Delivered

`chat-context-allocation` as a declarative table of share, region and
policy, with `chat-context-allocation-table`,
`chat-context-allocation-check` whose wording follows the policy, and
`chat-context-allocation-minimum-window`.

`chat-context-budget-panel` renders allowances beside measurements.
Measurements cover tool schemas by encoded size, memory, both halves of the
project instructions, and the conversation. Anything else shows as `-`; a
number nobody can trace is worse than an admitted gap.

Fixed shares total 35%, matching `chat-context-protected-max-ratio`;
compactable totals 65%. Tests assert both, so an edit cannot quietly promise
the same tokens twice.

## The finding worth keeping

Shares scale with the window; the cost of a tool set does not. A schema
costs the same on every model, so a rich tool set simply does not fit a small
window's share of it.

Concretely, at the shares chosen: 31.5K of tool schemas needs a 309K window,
11.9K of capability packs needs 350K. On a 128K model the entire tool
allowance is 13.4K, so tool groups have to be selected rather than all
enabled. `chat-context-allocation-minimum-window` reports this directly,
because the useful question is not whether a tool set is too big but which
models it fits on.

## Verification

727 tests, 0 unexpected. Panel smoke-tested in batch against a synthetic
session; allocation figures for 8K through 1M generated from the table
itself and copied into `docs/context-budget.md`.

## Not done

Per-category measurement is partial by design. Instrumenting the system
prompt, capability packs, MCP and subagent definitions means touching each
producer, and an estimate stapled on from outside would be the untraceable
number this deliberately avoids.
