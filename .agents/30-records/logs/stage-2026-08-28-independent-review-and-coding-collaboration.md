# Independent Review and Coding Collaboration

- Type: progress
- Attention: records
- Status: complete
- Scope: M16
- Tags: review, subagent, scheduler, worktree, merge, verification

## Implemented

- strict typed review findings with project-relative path, positive line,
  severity, title and evidence requirements
- duplicate and project-escape refusal
- fresh review child context built only from objective, base, diff, repo map and
  verification evidence
- read-only review profile with diff, repo-map and verification-result tools
- constrained second verifier for critical/high findings
- session audit events and a native jump-to-source findings view
- coding child declarations for goal, paths, resources, profile/model, budget
  and completion evidence
- hierarchical `path:` scheduler conflicts and independent session worktrees
- bounded parent outcomes without child transcript propagation
- merge checks for stale base, worktree ownership, path ownership,
  post-completion drift, parent path drift and patch applicability
- required verification after every applied child patch

## Evidence

- focused review/collaboration suite: 12/12 passed
- canonical suite: 1678/1678 passed after the added post-completion drift case
- deterministic seeded Review score: recall 100%, precision 87.5%
- review profile test: zero tools with write, destructive or outbound effects
- conflicting merge fixtures: parent path drift and stale base both refused
  before source bytes changed
- nonconflicting two-worktree fixture: both patches merged and verification ran
  after each merge

## Commands

```text
HOME=/tmp emacs -Q -batch -L tests/unit -l tests/unit/test-helper.el -l chat.el -l tests/unit/test-chat-code-review.el -l tests/unit/test-chat-code-collaboration.el --eval '(ert-run-tests-batch-and-exit "^chat-code-\\(review\\|collaboration\\)")'
emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit
git diff --check
```

## Remaining Work

M17 must connect runtime phase projection to the unified chat surface, complete
10,000-file performance evidence, run the final repeated coding benchmark and
publish the immutable acceptance comparison against M9.
