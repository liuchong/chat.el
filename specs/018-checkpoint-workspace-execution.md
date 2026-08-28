# Checkpoint, Workspace And Execution Runtime

Status: complete
Date: 2026-08-28
Roadmap: M6
Decision: 0024

## Goal

Make code work recoverable across restart, isolate optional sessions from the
source checkout and route local processes through one versioned execution
contract without confusing durable records with live operating-system state.

## Checkpoint Contract

`chat-checkpoint` schema version 1 contains:

- checkpoint, session and Turn IDs;
- reason, status and timestamps;
- conversation head message ID;
- workspace kind, root and optional Git observation;
- owned file entries with original state and last runtime-written digest;
- lifecycle boundaries and coverage limitations.

Every accepted user Turn creates a checkpoint before its message enters the
session. Direct file tools capture every resolved target before the first write.
One checkpoint keeps the first original snapshot for a path even when later
tool calls edit it again, while the post-write digest advances after each
successful call.

Snapshots live outside session JSONL. Session events carry IDs, counts and
decisions, not copied file bodies. Checkpoint records and snapshots are
versioned and reloadable from `chat-checkpoint-directory`.

## Recovery Rules

Code rollback:

1. validate checkpoint ownership and workspace identity;
2. compare each current owned path with its last runtime-written state;
3. refuse external drift unless force was explicitly requested;
4. restore original bytes, absence, executable mode or symbolic link;
5. verify the restored state and append the rollback attempt.

Conversation rollback creates a sibling branch at the saved conversation head.
The source session is immutable. Combined rollback performs code first, then
conversation, so a failed file safety check cannot create a misleading branch.

Code rollback never changes the Git index, branch, HEAD or unowned paths. Git
status captured at checkpoint time is observational. Changes made by shell
commands, terminal processes, ignored files or programs outside direct file
tools are reported as partial coverage.

## Workspace Contract

`chat-workspace` schema version 1 supports `checkout` and `worktree` kinds.
Worktree creation records:

- owner session ID;
- source repository and owned path;
- detached base revision;
- created, reconciled and released timestamps;
- active, needs-attention or released status.

The source checkout is never cleaned or rewritten. A worktree begins from an
explicit commit, so source working-tree changes remain protected in place.
Session working directory and code project root move together to the owned
worktree. Normal release requires a clean owned worktree; forced release must be
requested explicitly. Ownership is verified against both the durable record
and Git's registered worktree list before removal.

## Execution Contract

`chat-execution-request` schema version 1 contains an ID, backend, argv,
directory, environment, correlation IDs, idempotency, timeout and metadata.
Allowed idempotency classes are:

- `read-only`: no durable external effect is expected;
- `idempotent`: repeating the same request is declared safe;
- `non-idempotent`: repetition may duplicate an effect.

Each start creates a numbered durable attempt. The local backend owns an Emacs
process and updates the attempt exactly once. On restart, a running attempt
becomes `interrupted`; it is not restarted. Retry is always explicit, and a
non-idempotent retry requires renewed permission.

This is the M6 foundation contract. Spec 023 upgrades the live execution schema
to version 2 with policy, canonical roots, network, explicit environment and
process-tree cleanup requirements. Version-one records migrate to explicit
unrestricted `local`; they are never reclassified as isolated attempts.

The initial migration covers shell tools, background process tasks, external
subagents, stdio extension clients and code test processes. Model transport
processes remain in the Model Runtime because they implement request transport,
not task execution.

## Lifecycle Events

The runtime publishes versioned events for:

- checkpoint creation, capture, boundary update and rollback;
- workspace creation, reconciliation and release;
- execution start, finish, interruption and refused retry.

Events preserve session, Turn, task and parent correlation where available.
Payloads are bounded summaries and never contain snapshot bodies or complete
process output.

## Native UI

The chat surface provides commands to list checkpoints, create an explicit
checkpoint, roll back code, roll back conversation, perform combined rollback,
enable a worktree, inspect workspace state and release an owned worktree.
Recovery results redraw or switch the current chat buffer only after the core
operation succeeds.

## Acceptance

- old sessions load without checkpoint or workspace metadata;
- pre-existing dirty files survive a later owned-file rollback;
- new, changed, deleted, binary and executable files restore correctly;
- equal-path external drift blocks rollback unless force is explicit;
- conversation rollback creates a branch and does not truncate history;
- checkpoint and workspace records survive restart;
- dirty worktree cleanup refuses by default and forced cleanup is audited;
- startup interrupts stale attempts without creating a process;
- non-idempotent retry fails without renewed permission;
- migrated local execution preserves cancellation and correlation;
- no recovery path uses destructive repository reset or claims OS isolation;
- the offline canonical suite passes with no unexpected result.

## Verification

The canonical offline suite passes 1484/1484 with zero unexpected results.
Focused coverage proves owned rollback with pre-existing dirty work, drift
refusal and explicit force, new/deleted/binary/executable restoration,
conversation branching, restart reconciliation, dirty worktree cleanup,
interrupted execution recovery, retry permission, cancellation ordering and
session/Turn/task correlation. Regression tests also prove that a failed new
Turn cannot mutate the prior Turn's checkpoint, a symbolic link is restored as
the owned object, and a forged relative path cannot escape the workspace.

All touched Lisp files pass `check-parens` and byte compilation with only the
repository's established warnings. Static scans show that migrated execution
adapters no longer create private processes and that recovery code contains no
destructive repository reset path. No background service was started.
