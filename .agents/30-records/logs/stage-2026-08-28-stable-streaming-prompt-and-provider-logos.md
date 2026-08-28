# Stage: Stable Streaming Prompt And Provider Logos

- Type: log
- Attention: record
- Status: done
- Scope: project
- Date: 2026-08-28
- Tags: streaming, cursor, prompt, providers, logos

## What Changed

The input cursor no longer jumps from the window bottom back to the middle
while a live response grows above it.  Chat buffers now ask Emacs to scroll
only by the minimum amount needed to keep point visible.  The existing rule
that leaves a reader who scrolled upward alone remains unchanged.

The model prompt now resolves a protocol provider to its vendor before
choosing a mark.  User logo overrides still win, while a packaged monochrome
SVG set covers every vendor identity currently offered by the model switcher.
The packaged SVG is tinted from the active theme foreground at draw time.

## Reusable Lessons

When text is inserted before point, preserving point is not enough to preserve
the view.  Emacs redisplay may recenter an off-screen point unless the buffer
chooses conservative scrolling explicitly.  The stable policy belongs to the
major mode, not to every streaming callback.

Provider identity and vendor identity are different data.  UI branding must
use the vendor, while transport and requests continue using the provider.
Logo lookup therefore belongs after vendor normalization and before the
single-character fallback.
