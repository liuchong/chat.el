# Long Document Workflow Docs

- Type: log
- Attention: record
- Status: complete
- Scope: docs, help, workflow
- Tags: docs, help, code-mode, writing

## Summary

Captured the recommended long-document writing workflow in native code-mode help and human-facing docs so the guidance no longer lives only in transient conversation replies.

## Changes

- added a documentation workflow section to `chat-code-show-help`
- added a long-document workflow tip under `docs/tips/`
- updated README, code-mode usage docs, the docs index, and project status
- added regression coverage for help rendering so the new guidance stays visible

## Verification

- `emacs -Q -batch -L tests/unit -L lisp/core -L lisp/code -l tests/unit/test-helper.el -l tests/unit/test-chat-code.el -f ert-run-tests-batch-and-exit`

## Remaining

- consider later whether plain chat help should expose the same document-writing workflow guidance
