# 0007 - Context budget and declared resident context

## Status

Accepted, 2026-08-25.

## Problem

Two separate gaps, both about context.

A run could not see how much room it had left. The window was known only to
one display, which derived a request budget from it; everything else
compacted against a flat 8000 tokens regardless of whether the model offered
8k or 262k. Nothing told the model anything, so it could neither spend the
room it had nor economize on room it did not.

Separately, instruction files ask for part of themselves to stay resident and
unsummarized -- a rule stating that rules must not be thinned out, a suite
declared resident, a demand to reread originals rather than a paraphrase.
There was no mechanism to address, so the request held only while the agent
remembered it, which is what it was written to prevent.

## Decisions

### The window is measured, and the policy is stated separately from the numbers

`chat-context-budget-state` reports used, usable, remaining, and the split
between the fixed region and compactable history. Usable is the window minus
a reply reserve, because the window covers request and response together.

Disclosure follows the step budget's shape: the standing prompt carries the
*policy* -- history is summarized, not deleted, and standing instructions are
never summarized -- while the *numbers* appear only in a per-turn reminder
once usage is tight. A figure baked into the system prompt is wrong by the
time it is read, and repeating a count that does not matter yet trains the
run to ignore it.

The tight reminder names an action rather than reporting a shortage: state
your conclusions now, because a summary preserves what you wrote down and not
what you merely looked at. Reporting scarcity alone produces hoarding.

### An estimate may never fail a request

Contexts are assembled from several sources and a stray entry that is not a
message is a reason to report less, not to abort the turn.
`chat-context-budget-measurable` filters instead of raising. This was found
by a test that passes sentinel symbols to assert pass-through: the budget
call turned them into an error that killed the run.

### Residency is declared with an HTML comment

Three properties had to hold at once, and this syntax is the only candidate
that has all three: Markdown hides it so the file still reads cleanly for
people; a tool that does not implement the scheme sees an ordinary comment
and behaves exactly as before, so marking a shared file breaks nothing; and
it is line-oriented, so parsing needs no Markdown reader and cannot be
confused by prose that discusses the syntax.

Four forms: a fenced block, a marked heading covering its section through
the next heading of the same or higher level, a marked single line, and a
heading whose name matches a configured list.

The syntax is fixed rather than configurable. A declaration that only works
under one client's settings is not a guarantee, and a file that must be
re-marked per tool will drift.

The heading-name fallback is an exact match on a configured name, not
inference from prose. A scheme that guesses is a scheme that silently stops
guaranteeing things, which is the failure being repaired.

An unclosed block runs to end of file. It fails toward keeping text, since
failing the other way drops the guarantee silently.

### A declaration is a request, and the cap is what makes it safe

Resident text is honoured up to `chat-context-protected-max-ratio` of usable
context. Past that the excess is demoted to compactable and the overflow is
reported. Obeying an unbounded declaration would let one file fill the window
and leave a session able to do nothing but recite its own instructions.

Document order decides what survives, and once one block does not fit,
everything after it is demoted too. A partial keep that skips a middle block
would leave the guarantee looking satisfied while a rule is missing.

Granularity is the blank-line-separated block. Real rule files are long
bullet runs without blank lines, so a section tends to be one block: it fits
whole or is demoted whole. Verified against a 20228-token rule file, where a
2000-token cap kept 944 tokens because the next block alone exceeded the
remainder. Marking specific spans beats marking everything and letting the
cap cut.

### Undeclared instruction text becomes compactable rather than truncated

The size cap now applies to the compactable part alone. Truncating merged
instructions by character count cut whatever sat at the end, so a long file
lost its last rules without saying so. Summarizing them is strictly better,
and the declared spans are exempt from the cap entirely.

## Consequences

- Compaction in the regular display now follows the model's window instead of
  a flat 8000. Code mode keeps its own more detailed budget, which also
  accounts for output tokens and a safety margin; the two should converge
  later, and the simpler one must not replace the more careful one.
- Callers that can route the two parts differently should use
  `chat-project-instructions-partitioned`. The single-string entry point
  keeps working and puts resident text first.
- An overflowing fixed region is reported once per run, not per step: it is a
  configuration problem for a person, and repeating it would bury the run's
  own output.
