# Lesson Item

- Type: lessons
- Attention: records
- Status: active
- Scope: diagnostics
- Tags: diagnostics, async, tests, event-order

## Lesson

Async diagnostics tests should not assume that the final recorded event is always the response event.

## Why It Matters

- Immediate mocked callbacks can complete before later metadata events such as handle attachment
- Brittle assertions create false regressions even when the lifecycle model is correct

## Guard

- Assert on phase and search the timeline for the expected event summary instead of hard-coding one final event slot
