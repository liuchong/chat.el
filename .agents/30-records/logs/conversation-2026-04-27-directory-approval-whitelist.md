# Directory Approval Whitelist

- Type: log
- Attention: record
- Status: complete
- Scope: approvals, file-tools
- Tags: approval, whitelist, directory, apply-patch

## Summary

Added a directory-scoped approval whitelist for file-writing tools so repeated writes under one approved subtree no longer need repeated confirmation.

## Changes

- added `chat-approval-always-approve-directories`
- added a new approval decision path for directory-scoped file-write approvals
- limited directory whitelisting to file-writing tools with clear directory semantics
- extracted target directory scope for `files_write`, `files_replace`, `files_patch`, and `apply_patch`
- emitted directory whitelist update events for observers and request-panel consumers
- documented the new shortcut and scope in README and code-mode usage docs

## Verification

- `emacs -Q -batch -L tests/unit -L lisp/core -L lisp/tools -l tests/unit/test-helper.el -l tests/unit/test-chat-approval.el -f ert-run-tests-batch-and-exit`
- `emacs -Q -batch -L tests/unit -L lisp/core -L lisp/tools -l tests/unit/test-helper.el -l tests/unit/test-chat-tool-caller.el --eval '(ert-run-tests-batch-and-exit "chat-tool-caller-directory-whitelist-auto-approves-file-write")'`

## Notes

- Running the full `test-chat-tool-caller.el` file in this environment still hits two unrelated existing shell-tool test failures around `chat-tool-shell-enabled` dynamic binding. The new directory-whitelist path was verified with a targeted tool-caller test instead.
