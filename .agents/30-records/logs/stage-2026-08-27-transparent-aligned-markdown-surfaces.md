# Stage: Transparent And Aligned Markdown Surfaces

- Type: logs
- Attention: records
- Status: complete
- Scope: markdown-rendering
- Tags: markdown, tables, faces, themes, regression

Date: 2026-08-27
Spec: 005 (Markdown display engine)

## What the screenshot disproved

The first visual pass added hard-coded light and dark backgrounds to tables,
code blocks and the MDP machine view. On the active light theme those faces
became white rectangles, and `:extend t` turned a code line into a full-width
white band. The intended visual hierarchy did not justify changing the buffer
background at all.

The table alignment test also proved too little. It asserted that a
fixed-pitch face existed somewhere in each cell's face list. The renderer had
appended it behind the transcript channel face, so a preceding proportional
font could still win. The code expressed an intent without enforcing it.

## Correction

- All three document surfaces now inherit the current buffer background.
- The table structural face is prepended as a single face, producing the
  priority order `table -> inline style -> transcript channel`.
- Column borders use absolute `:align-to` display positions. This handles CJK
  fallback fonts whose real glyph widths do not exactly follow character-cell
  arithmetic even after the table face wins.
- Foreground colours still fall through because the table face owns only the
  font family.
- The regression test supplies an explicit variable-pitch channel face and
  checks that table headers, body cells and inline-code cells all put the
  fixed-pitch structural face first.
- Separate tests reject any explicit background on tables, code blocks or the
  MDP machine view.

## Verification

Focused rendering tests passed 42/42. The complete suite passed 1367/1367
with zero unexpected results. After reloading and redrawing the live NS Emacs
buffer under the reported theme, all ten lines of the inspected mixed-script
table measured exactly 891 pixels, and visual inspection confirmed aligned
borders with no background panels.

## Acceptance

The user confirmed the final live rendering as a substantial improvement.
The accepted screenshot includes mixed Latin and CJK table cells, inline code,
headings, nested lists and ordinary prose under the actual translucent theme;
the table borders remain aligned and no document element paints a white panel.
