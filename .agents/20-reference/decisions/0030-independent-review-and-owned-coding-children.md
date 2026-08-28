# 0030 - Independent Review and Owned Coding Children

- Type: decision
- Attention: reference
- Status: accepted
- Scope: coding-agent
- Tags: review, collaboration, worktree, merge, verification

## Context

An editing Agent's own explanation is not independent evidence, and parallel
children can silently overwrite each other when goals do not declare resource
ownership. A worktree separates Git state, but does not by itself make a child
read-only, authorize a merge or resolve conflicting edits.

## Decision

Review runs in a fresh child session under the built-in `review` profile. Its
only input is the objective, base revision, bounded diff, ranked repo-map facts
and typed verification evidence. Output must pass a strict finding parser;
critical and high findings may receive a second constrained verdict that can
only confirm, downgrade or reject the original record.

Coding children declare allowed paths, scheduler resources, profile/model,
budget and completion evidence before launch. Hierarchical path locks prevent
conflicting writers from running together. Nonconflicting children receive
session-owned detached worktrees. The merge gate recomputes changed paths,
checks base revision, ownership, post-completion drift, parent path drift and
patch applicability before applying bytes. It never resolves a conflict.
Successful application is followed by required project verification.

## Consequences

Parents receive bounded summaries, changed paths, verification ids and
checkpoint ids rather than child transcripts. Review findings and merge states
are auditable session events and findings are navigable to source lines. A
conflicted worktree remains available for inspection; only a verified merge is
released automatically.
