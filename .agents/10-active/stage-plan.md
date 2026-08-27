# Stage Plan

- Type: progress
- Attention: active
- Status: active
- Scope: agent-runtime
- Tags: stage, plan, checkpoints, worktrees, backends

## Goal

Deliver M6: checkpointed recovery, optional worktree ownership and one execution
backend contract for local and future isolated work.

## Completed

- M0-M4 runtime contracts, lifecycle events, model capabilities, extensions and
  unified tasks
- M5 typed content with durable image and file attachments
- capability preflight and three offline provider request fixtures
- attachment input, clipboard staging, preview, transcript replay and context
  budgeting
- canonical verification at 1466/1466

## Next Steps

1. Define the checkpoint and execution backend schemas before changing edit
   behavior.
2. Record a checkpoint before each user turn that may directly modify files.
3. Separate code rollback, conversation rollback and combined rollback.
4. Add optional worktree-backed sessions with explicit ownership and cleanup.
5. Reconcile dirty working trees and external file changes without claiming
   rollback coverage the runtime does not own.
6. Map local execution through the backend interface and leave the remote
   adapter slot versioned but unimplemented.
7. Prove restart recovery, branch preservation, cancellation and cleanup with
   offline tests before adding the native recovery UI.

## Risks

- Git snapshots can accidentally imply ownership of unrelated user changes.
- Conversation branching and filesystem rollback have different boundaries and
  must never be coupled implicitly.
- A worktree is isolation from the current checkout, not an operating-system
  sandbox.
- Backend recovery must not resurrect stale processes or repeat non-idempotent
  actions without renewed permission.

## Next Entry

Record the checkpoint/backend decision and M6 spec before implementation begins.
