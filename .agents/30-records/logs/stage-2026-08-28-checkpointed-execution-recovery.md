# Stage: Checkpointed Execution Recovery

- Type: logs
- Attention: records
- Status: complete
- Scope: agent-runtime
- Tags: checkpoints, worktrees, execution, recovery, ownership

Date: 2026-08-28
Spec: 014, 018
Decision: 0024

## Result

M6 adds three versioned runtime contracts. `chat-checkpoint` captures direct
file targets before their first write and records the last successful runtime
state. `chat-workspace` owns optional detached worktrees without modifying the
source checkout. `chat-execution` routes local shell, background, test, stdio
extension and external-agent processes through durable numbered attempts.

Code and conversation recovery are independent. Code rollback restores only
runtime-owned paths and refuses external drift unless force is explicit.
Conversation rollback creates a sibling session at the saved message head.
Combined recovery performs code first, so a filesystem refusal cannot create a
misleading branch.

Restart reconciliation marks vanished execution attempts interrupted and
missing or inconsistent worktrees as needing attention. It never recreates a
process. Non-idempotent retry requires renewed permission. Native commands list
and create checkpoints, perform each rollback form, enable or inspect a
worktree and release owned workspace state.

## Correctness Details

- Session, Turn, task and parent correlation survives execution adapters.
- Environment values and process output are excluded from durable requests.
- Attempt completion and cancellation reach one terminal state.
- Pre-existing staged, unstaged and untracked source work is not cleaned.
- Binary bytes, executable modes, symbolic links, file absence and deletion are
  recoverable for captured direct targets.
- A new Turn that fails before checkpoint creation cannot mutate the prior
  Turn's checkpoint.
- Dirty owned worktrees refuse normal cleanup; force is explicit and audited.
- Shell, workflow and delegated execution record partial coverage because their
  file effects cannot be inferred precisely.
- Model request transport remains in the Model Runtime rather than being
  mislabeled as task execution.
- Worktrees isolate checkouts; neither worktrees nor Lisp wrappers are described
  as operating-system sandboxes.

## Verification

The canonical suite passes 1484/1484 with zero unexpected results. Focused
tests cover restart, retries, cancellation races, correlation, owned rollback,
external drift, binary and executable restoration, conversation branching,
worktree ownership and lifecycle reconciliation. All touched Lisp files pass
`check-parens` and byte compilation with only established repository warnings.

Static scans confirm that the five migrated execution adapters do not call
private process creation and that checkpoint/workspace recovery contains no
destructive repository reset command. All commands ran in the foreground under
the repository memory cap; no server or background process was started.

## Next Stage

M7 introduces provenance-aware memory, correlated Trace reconstruction and
deterministic Agent evaluations over the runtime contracts completed so far.
