# Decision 0024

- Type: decisions
- Attention: reference
- Status: accepted
- Scope: agent-runtime
- Tags: checkpoints, recovery, worktrees, execution, ownership

## Title

Recover only runtime-owned changes and never resurrect live execution

## Context

Conversation history, file contents and operating-system processes have
different lifetimes. Treating them as one undo stack would either destroy user
work or claim recovery for state the runtime cannot own. A full repository
reset is especially unsafe when the checkout already contains staged,
unstaged or untracked work.

Long-running execution has a related boundary. Durable intent can survive an
Emacs restart, but process objects, callbacks, timers and open pipes cannot.
Repeating a command merely because its process disappeared can duplicate a
non-idempotent action.

## Decision

`chat-checkpoint` schema version 1 is the recovery contract. A checkpoint is
created before a recorded user Turn. It stores the session and Turn identity,
the conversation head, workspace identity, Git observation when available,
owned file snapshots, post-write digests, lifecycle boundaries and explicit
coverage limitations.

File snapshots are lazy but pre-write: a direct file tool resolves all target
paths and captures each original state before execution. Successful completion
records the resulting digest. A path is owned only after this sequence. Code
rollback restores owned paths only. If the current bytes of an owned path no
longer match the last runtime-written digest, rollback refuses unless the user
explicitly forces it. Unowned shell, terminal, ignored-file and external
changes remain untouched and are reported as outside coverage.

Conversation rollback creates a new session branch through the message that
preceded the checkpoint. It never truncates the original session. Combined
rollback performs the checked code rollback first and creates the conversation
branch only after the filesystem operation succeeds.

`chat-workspace` schema version 1 records optional worktree ownership. A record
contains the owner session, source repository, detached base revision, owned
path and lifecycle status. Creation never moves or cleans the source checkout.
Normal cleanup refuses a dirty owned worktree; forced cleanup is explicit and
audited. Missing or mismatched worktrees become `needs-attention` after restart.

`chat-execution-request` and `chat-execution-record` schema version 1 form the
backend boundary. Requests carry command argv, directory, environment,
session/Turn/task/parent correlation and an idempotency class. Attempts are
durable facts. Startup changes an unfinished attempt to `interrupted` without
starting anything. Read-only and idempotent requests may be explicitly retried;
non-idempotent requests require renewed permission. Backend implementations
own native handles, while callers retain backend-neutral execution IDs.

The first backend is `local`. A future isolated or remote backend must preserve
the same request ID, task lineage, attempt history and event correlation. A
worktree changes a command's working directory; it is not an operating-system
sandbox and is never described as one.

## Consequences

Dirty source work survives ordinary recovery because rollback does not use
reset, checkout or a repository-wide replacement. Recovery is narrower than a
machine snapshot, but its guarantee is precise and auditable. Commands that can
change unknown files make checkpoint coverage partial rather than silently
expanding runtime ownership.

The session event stream records checkpoint creation, capture, rollback,
workspace lifecycle and execution attempts. Restart reconstructs intent and
attention state without retaining stale process, timer, buffer or callback
objects.

Worktree removal and forced rollback remain user commands. No automatic cleanup
may discard a dirty owned workspace, and no automatic retry may repeat an
execution attempt.
