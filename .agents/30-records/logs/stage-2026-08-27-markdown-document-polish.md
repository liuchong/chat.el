# Stage: Markdown Document Polish

- Type: logs
- Attention: records
- Status: complete
- Scope: markdown-rendering
- Tags: markdown, tables, streaming, display

Date: 2026-08-27
Spec: 005 (Markdown display engine)

## What looked unfinished

The renderer was active in the reported buffer: headings, bullets and inline
markup already carried faces. Two things made it look as though it was not.
The model had wrapped an entire demonstration in a `markdown` fence, whose
contents are intentionally source, and the table renderer measured raw cell
source before hiding inline markers. A value such as `` `main` `` therefore
reserved six columns while displaying four.

The table also mixed proportional body text, bold headers and fixed-pitch
inline code. Character-column arithmetic cannot produce a stable pixel edge
when each row uses a different metric.

## What changed

- Table widths are measured from the final screen text after `invisible` and
  string-valued `display` properties are applied.
- Every table row puts one fixed-pitch structural face ahead of channel and
  inline faces, so that metric actually wins. Source pipes display as quiet
  Unicode borders, and separator rows display as joined box-drawing rules.
- Visibility-aware truncation preserves hidden closing markers, so copied
  Markdown remains valid.
- Headings have a clearer hierarchy; fenced code has labelled top and bottom
  rails plus a body rail; blockquotes retain a visible rail.
- Tables, code blocks and machine views deliberately inherit the buffer
  background. Their structure comes from typography and rails, never a panel
  of hard-coded light or dark colour.
- The output-format prompt now forbids wrapping an ordinary answer or a
  Markdown rendering demonstration in a `markdown` fence.
- The README shortcut was corrected from the nonexistent `C-c C-;` to the
  actual `C-c C-u` binding.

## Design boundary

The review compared two broad implementation families: replacing source with
rendered text while storing a reconstruction copy in properties, and keeping
the source in place while changing only its display. chat.el keeps the second,
smaller design. Source-preserving display properties and deterministic
character widths are central invariants, and the same pure result must be
produced during streaming, redraw and reopen.

An offset watermark that survives text movement, backing up over a table that
is still receiving rows, and testing layout against the actual display remain
useful implementation techniques. Pixel-adaptive table layout is a possible
later enhancement, but only if it preserves the invariants above and avoids
window-dependent session output.

## Verification contract

Focused ERT tests cover Unicode borders, one table metric, hidden-marker width,
source-preserving truncation, labelled code rails and blockquote rails. Prompt
tests assert the fence boundary and its reason. The full suite is run after the
following MDP preview stage is integrated.
