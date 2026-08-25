# Resident Context

Instruction files routinely ask for part of themselves to stay in view: a
rule saying rules must not be thinned out, a suite declared resident, a
demand to reread the original wording rather than a paraphrase. Those
requests are addressed to a mechanism that usually does not exist, so they
hold only for as long as the agent happens to remember them -- which is the
situation they were written to prevent.

This is that mechanism. An instructions file marks the spans that must
survive verbatim; compaction summarizes everything else and leaves those
spans alone.

## Syntax

The marker is an HTML comment. Markdown hides it, so the file still reads
cleanly for people; a tool that does not implement this scheme sees an
ordinary comment and behaves exactly as it did before, so marking a shared
file breaks nothing.

**The syntax is fixed, not configurable.** A declaration that only works
under one client's settings is not a guarantee.

### Block

```markdown
<!-- chat:resident -->
- RULE-01 — never thin out these rules
<!-- chat:end -->
```

An unclosed block runs to the end of the file. It fails toward keeping
things, because failing the other way would silently drop the guarantee.

### Section

```markdown
## Non-negotiables <!-- chat:resident -->

- RULE-01 — ...
- RULE-02 — ...

## Background
```

The section is resident through to the next heading at the same or a higher
level. Deeper subsections stay inside it. No closing marker is needed.

### Line

```markdown
- ordinary guidance, may be summarized
- RULE-02 — never thin out rules <!-- chat:resident -->
```

Only that line is resident.

### Heading name

A heading whose text matches `chat-context-resident-headings` is resident
with no marker at all:

```markdown
## Resident Rules

- RULE-01 — ...
```

The default list is `Resident Rules`, `Resident Context`,
`Non-Negotiables`, `常驻规则`, `常驻上下文`, matched case-insensitively
against the exact heading text. This is a name match, not an attempt to
read intent from prose: a scheme that guesses is a scheme that quietly
stops guaranteeing things.

## What a declaration gets you

Declared text is placed in the fixed region of the request context. Nothing
summarizes it, and it is exempt from
`chat-project-instructions-max-chars`.

Undeclared text from the same file becomes compactable. When context gets
tight it is summarized rather than truncated -- which is a real improvement
over the previous behaviour, where the merged instructions were cut at a
character count and whatever sat at the end disappeared without a word.

## The cap

A declaration is a request, not a command.

Resident text is honoured up to `chat-context-protected-max-ratio` of the
usable context window (35% by default). Past that the excess is demoted to
compactable and a warning names the overflow. A file that declared more
than the window can hold must not be able to leave a session with no room
to work in.

**Document order decides what survives.** Blocks are kept from the top
until the cap is reached, and once one block does not fit, everything after
it is demoted too -- keeping a small tail after dropping a large middle
would leave the guarantee looking satisfied while a rule in the middle is
gone. So put the rules that matter most first.

### Granularity

The unit is a block separated by a blank line. A long run of bullets with no
blank lines between them is one block: it either fits whole or is demoted
whole.

This matters for real rule files, which tend to be exactly that shape. If a
file is near the cap, marking specific spans gives far better results than
marking everything and letting the cap decide, because the cap can only cut
at blank lines.

## Inspecting it

`M-x chat-context-budget-report` prints what the current session spends,
how much of that is fixed, and the warning if the fixed region is over its
cap.

## Configuration

| Variable | Meaning |
|---|---|
| `chat-context-resident-headings` | Heading names that imply residency |
| `chat-context-protected-max-ratio` | Largest share of usable context the fixed region may hold |
| `chat-context-default-window` | Window assumed when a provider declares none |
| `chat-context-reply-reserve-ratio` | Share of the window held back for the reply |
| `chat-context-compact-at-ratio` | Usage that triggers compaction |
