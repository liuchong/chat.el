# Stage 2026-08-25 - Context budget and declared resident context

## Goal

Two gaps. A run could not see its context window, and instruction files
could ask for spans to stay unsummarized with nothing on this side to honour
the request.

## Findings before building

- `:context-window` existed but only one provider declared it, and only code
  mode consumed it. The regular display passed nil and compacted against a
  flat 8000 tokens regardless of the model.
- The protected region in compaction is exactly the leading system messages,
  and it had no ceiling. It grows through ordinary use -- a longer
  instructions file, more remembered facts -- and nothing shrinks it.
- `chat-project-instructions` truncated merged instructions with `substring`
  at 32768 characters, so a long rule file lost its tail silently. That is
  worse than compaction, which at least leaves a summary.

## Delivered

### `lisp/core/chat-context-budget.el`

- `chat-context-budget-state`: window, usable (window minus a reply
  reserve), used, remaining, and the split between fixed and compactable.
- Disclosure split by volatility: the policy goes in the system prompt, the
  numbers only in a per-turn reminder once usage is tight.
- The tight reminder asks for conclusions to be stated now, since a summary
  keeps what was written down and not what was merely read.
- `chat-context-budget-measurable` filters unmeasurable entries, because an
  estimate must not be able to fail a request.
- `chat-context-budget-report` for inspecting a session.

### `lisp/core/chat-context-resident.el`

Four declaration forms parsed from HTML comments: fenced block, marked
heading covering its section, marked line, and configured heading name.
`chat-context-resident-apply-cap` honours declarations in document order up
to the cap and demotes the excess.

### Wiring

- The regular display compacts against the model's window.
- `chat-project-instructions-partitioned` returns the two parts; the cap
  applies to the compactable one only.
- An overflowing fixed region is reported once per run.

## Bugs found while building

- `chat-context-budget-state` raised on a context containing a non-message
  sentinel, which the dispatch turned into a failed run. Two code-mode tests
  caught it. Fixed by filtering rather than raising.
- `chat-context-resident-apply-cap` reported an overflow of 14 tokens for
  19284 tokens of demoted text: `nreverse` on the accumulator for one field
  left the variable pointing at a single cons, and a later field measured
  that. Found by checking that kept plus overflow equalled the input on a
  real 20228-token rule file; the unit test asserted only that overflow was
  positive and passed on the broken version. Both the fix and a test that
  compares the count against the returned text are in.

## Verification

`emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`:
717 tests, 0 unexpected.

Against a real 20228-token rule file:

- unmarked: 0 resident, 20228 compactable, so an existing file is unaffected
- one heading marked: 1073 resident, correctly stopping at the next section
- whole file marked under a 2000 cap: 944 kept, 19284 demoted, summing
  exactly to the input

## Known limitation

Granularity is the blank-line-separated block. Rule files are long bullet
runs without blank lines, so a section is usually one block and the cap can
only cut between sections. That is why 2000 kept only 944: the next block
alone exceeded the remainder. Documented; marking specific spans is the
answer, not a finer splitter.

## Not done in this stage

- Code mode keeps its own request budget, which also accounts for output
  tokens and a safety margin. The two should converge, and the simpler one
  must not replace the more careful one.
- No compaction of the resident region itself, by design.
- Still pending from the previous stage: neither display renders from
  `chat-transcript-plan`, no fold interaction, no `auto` mechanism, and the
  `/subagent`, `/send`, `/call_ai` specs are unwritten.
