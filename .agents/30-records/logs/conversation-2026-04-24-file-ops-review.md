# File Operations Review

- Type: log
- Attention: record
- Status: complete
- Scope: file-editing
- Tags: review, replace, patch, apply-patch

## Summary

Reviewed `chat-files.el` search-replace and unified-diff patch handling against the current unit-test matrix.

## Result

- `chat-files-replace` provides constrained literal and regexp replacement with selector validation, no-op refusal, and stable `Edit failed:` normalization for direct file-path failures.
- `chat-files-patch` applies multiple search-replace operations atomically on in-memory content before writing once, preserving replace-family diagnostics and adding patch-family errors for malformed patch entries and net no-op sequences.
- `chat-files-apply-patch` parses Codex-style patch envelopes into add, delete, and update operations, plans all file-state transitions first, then commits atomically so multi-file failures do not leave partial writes behind.
- Unified-diff support includes metadata skipping, move-only updates, pure insert/delete hunks, newline-marker compatibility, inaccurate header-count tolerance, and stable `apply_patch verification failed:` error normalization.
