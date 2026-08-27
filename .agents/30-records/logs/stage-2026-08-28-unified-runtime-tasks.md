# Stage: Unified Runtime Tasks

- Type: logs
- Attention: records
- Status: complete
- Scope: agent-runtime
- Tags: tasks, scheduler, cancellation, recovery, subagents, ui

Date: 2026-08-28
Spec: 014, 016
Decision: 0022

## Result

M4 replaces separate work identities with `chat-task` version 1. Foreground
chat runs, background commands, session workflows and both subagent backends
now project into one atomic registry, one terminal invariant and one lifecycle
stream. A bounded scheduler admits parallel work only when declared resources
do not conflict.

The native task tree shows parentage and state without expanding payloads into
the list. A separate detail buffer exposes checkpoints, resources and bounded
outcomes. Cancellation and workflow recovery route through their owning
adapters, including after the workflow's session is reloaded.

## Correctness Details

- Terminal states cannot conflict or emit twice.
- Cancellation tokens and adapter callbacks run at most once.
- Parent policy is explicit: cancel, detach or wait.
- A read may share a resource with another read; any matching write serializes.
- Persisted running tasks load as interrupted without a live runner.
- Future schemas fail before rewrite.
- Legacy background records import a unified copy without rewriting the source.
- Foreground task tracking is enabled on the real UI path, not every kernel
  probe.
- Workflow approval and failure states carry bounded checkpoints.
- Subagent tasks inherit the active parent and pass their id into child session
  metadata for deeper work.
- Existing workflow, process and subagent APIs remain compatibility adapters.

## Verification

The canonical suite passes 1444/1444 with zero unexpected results. New tests
cover the core state machine, bounded scheduling, cancellation, migration,
foreground tracking, workflow projection, subagent parentage and task views.
All touched Lisp files pass `check-parens` and byte compilation with only the
repository's established warnings.

No background service was started. Test processes ran in the foreground under
the repository memory cap.

## Next Stage

M5 introduces typed multimodal content while preserving the text-only session
and task behavior established through M4.
