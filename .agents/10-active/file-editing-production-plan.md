# File Editing Production Plan

- Type: plan
- Attention: active
- Status: complete
- Scope: file-editing
- Tags: replace, patch, apply-patch, tests

## Goal

Bring the file-editing chain to production-grade reliability, centered on:

- `files_replace`
- `files_patch`
- `apply_patch`
- stable error families
- dense regression protection

## Stage 1: Unify Replace Selector Semantics

### Files

- `lisp/core/chat-files.el`
- `tests/unit/test-chat-files.el`

### Tasks

1. Define the exact combination rules for `all`, `expected_count`, `line_hint`, and `regexp`.
2. Define stable errors for invalid selector inputs.
3. Keep line-scoped errors stable and explicit.
4. Keep no-op and net no-op semantics distinct and deterministic.

### Acceptance

- Every selector combination has unit coverage.
- Error text is stable and does not leak low-level failures.

## Stage 2: Strengthen Search Patch Semantics

### Files

- `lisp/core/chat-files.el`
- `tests/unit/test-chat-files.el`

### Tasks

1. Define failure propagation across multi-step search patches.
2. Keep multi-step search patches atomic.
3. Cover:
   - later search patch failure rollback
   - net no-op search patch sequences
   - regexp patch plus selector combinations
   - line-hint failure propagation

### Acceptance

- Search-patch sequences never dirty-write on failure.
- Search-patch failures stay aligned with direct replace failure families.

## Stage 3: Strengthen Unified Diff and Apply Patch Parsing

### Files

- `lisp/core/chat-files.el`
- `tests/unit/test-chat-files.el`

### Tasks

1. Add more AI-generated patch shapes:
   - multi-hunk same-file updates
   - pure insert and pure delete
   - mixed update plus insert plus delete
   - move-only, move plus update, move plus recreate
   - add, delete, move, update combinations
2. Add more metadata compatibility:
   - `diff --git`
   - `index`
   - `---`
   - `+++`
   - newline markers
3. Keep parser-time and apply-time failures clearly separated.

### Acceptance

- Codex-style patch compatibility improves further.
- Patch failures land in a small stable set of error families.

## Stage 4: Add Patch Recovery Diagnostics

### Files

- `lisp/core/chat-files.el`
- `tests/unit/test-chat-files.el`

### Tasks

1. Split patch failures into clear families:
   - malformed patch
   - invalid header
   - invalid payload
   - ambiguous hunk
   - missing source context
   - target conflict
   - path misuse
2. Make failure text suitable for AI retry instead of guesswork.
3. Add regression coverage for each family.

### Acceptance

- `apply_patch verification failed: ...` stays semantically stable.
- Same-class failures do not drift into unrelated messages.

## Stage 5: Complete Direct Edit Path Hardening

### Files

- `lisp/core/chat-files.el`
- `tests/unit/test-chat-files.el`

### Tasks

1. Unify semantics for directory targets, missing targets, parent creation, append, new files, and empty files.
2. Keep direct edit failures inside the `Edit failed: ...` family.
3. Add consistency coverage across:
   - `files_write`
   - `files_replace`
   - `files_patch`
   - `files_insert_at`

### Acceptance

- Direct edit paths do not leak raw `insert-file-contents` or `write-region` style failures.
- All direct edit entrypoints behave consistently.

## Stage 6: Test-Heavy Finish

### Files

- `tests/unit/test-chat-files.el`
- additional focused unit files if the matrix becomes too large

### Tasks

1. Expand helper-level and matrix coverage for:
   - selector matrix
   - regexp matrix
   - line-hint matrix
   - patch composition matrix
   - path misuse matrix
   - atomic rollback matrix
2. Prefer helper-level tests over only broad end-to-end tests.
3. Keep running:
   - `emacs -Q -batch -L tests/unit -L lisp/core -l tests/unit/test-helper.el -l tests/unit/test-chat-files.el -f ert-run-tests-batch-and-exit`
   - `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`

### Acceptance

- File editing becomes one of the densest protected areas in the repository.
- Regressions in the editing chain become fast to localize.

## Completion

Completed on 2026-04-24 after selector validation, search-patch failure-family hardening, unified-diff coverage expansion, direct-edit error normalization, and full regression verification.

## Completion Criteria

The plan is done only when all of these are true:

1. `files_replace`, `files_patch`, and `apply_patch` all expose stable error families.
2. Common AI-generated patch shapes are broadly covered.
3. Direct edit and patch edit paths are both protected by atomic semantics.
4. Full regression stays green.
5. `chat-files.el` is no longer an obvious reliability weak point.

## Execution Order

1. Stage 1
2. Stage 2
3. Stage 4
4. Stage 3
5. Stage 5
6. Stage 6
