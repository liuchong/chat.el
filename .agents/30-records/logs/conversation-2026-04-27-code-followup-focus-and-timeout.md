# Code Follow-Up Focus And Timeout

- Type: log
- Attention: record
- Status: complete
- Scope: code-mode, file-tools, approval
- Tags: code-mode, focus, timeout, follow-up

## Summary

Fixed a code-mode failure pattern where a short follow-up like "optimize it" could drift away from the previously reviewed file, burn time rediscovering targets, and eventually fail on the generic 180 second async timeout without landing an edit.

## Changes

- added a shared `chat-files--tool-target-paths` helper for canonical file-target extraction across file tools and `apply_patch`
- switched approval directory-scope derivation to reuse that shared helper instead of maintaining its own patch parsing path logic
- taught code-mode to promote the latest single-file tool target into session focus and append tracked file targets back into context
- tightened the code-mode system prompt so vague follow-ups prefer the current focus or most recently inspected file before broad scanning
- split tool-loop follow-up timeout from the generic async request timeout so post-tool synthesis gets a larger budget
- added regression tests for shared target extraction, approval reuse, focus promotion, and tool-loop follow-up timeout behavior

## Verification

- `emacs -Q -batch -L tests/unit -L lisp/core -L lisp/code -L lisp/tools -L lisp/ui -l tests/unit/test-helper.el -l tests/unit/test-chat-files.el -l tests/unit/test-chat-approval.el -l tests/unit/test-chat-request-diagnostics.el -l tests/unit/test-chat-request-panel.el -l tests/unit/test-chat-code.el -f ert-run-tests-batch-and-exit`

## Remaining

- the current buffer banner still does not rewrite its static `Focus:` line live when tool activity changes the session focus, even though subsequent requests already use the new focus internally
