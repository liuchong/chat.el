# Delayed Model Switching Audit

- Date: 2026-09-01
- Scope: delayed model identity, command lifecycle and input-boundary UI
- Status: complete
- Implementation revision: `ad52243a0727f35cee1d1a72b4f9eacfa6c82854`

## Result

The existing delayed-switch design already matched the required request
semantics. Prompt selection prepares a target without activating it, `/model`
creates a pending operation without interrupting the current request, and each
send mode captures one atomic provider/model target at submission. Idle, insert,
queue, interrupt and later continuation boundaries all preserve that identity.

The audit found one missing UI boundary case. A collapsed input work shelf and
the live transcript shared a marker position, but only the shelf start advanced
when live text was inserted. The resulting reversed shelf region was invisible
while collapsed. Opening the shelf after live output could then delete the live
answer and transient model-switch row.

## Boundary Contract

The physical tail order is now invariant:

1. committed transcript and current live answer;
2. transient pending model-switch row;
3. optional expanded input work shelf;
4. input divider, prepared model prompt and editable input.

Both shelf boundary markers advance together while the shelf is collapsed and
live text arrives. During shelf rendering, the start is temporarily fixed before
the shelf's own text while the end advances; their normal live-tail behavior is
restored even if rendering exits abnormally. Initialization keeps both markers
fixed until the divider and prompt have been inserted.

## Failure-Guided Development

The first new placement assertion failed because a collapsed shelf has a
zero-length region and its old marker did not represent visible ordering. Testing
an actual open TODO shelf exposed the implementation defect rather than a weak
assertion. Stage-by-stage probes of setup, live render, shelf render and prompt
render then showed the region reversal directly.

The reusable lesson is that two logical regions sharing one Emacs insertion
boundary need paired marker semantics. Testing only the collapsed appearance is
insufficient: open the secondary region, grow the primary region again, and
assert text preservation plus all four boundary positions.

This was also useful long-goal evidence. A new request should first be reconciled
with the current spec and call path. Existing behavior can be retained, missing
acceptance coverage added, and only the contradicted boundary repaired. That
avoids both duplicate implementation and an unexamined claim that the goal is
already complete.

## Verification

- model-selection and command-focused tests: 14/14 passed;
- input work-shelf tests: 5/5 passed, including 1000 refreshes;
- target byte compilation passed with no repository `.elc` artifacts;
- canonical clean-revision suite: 1958/1958 passed;
- `git diff --check` passed before the implementation commit;
- implementation commit was pushed to `origin/master`.

