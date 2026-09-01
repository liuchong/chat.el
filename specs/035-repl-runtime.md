# Spec 035: Persistent REPL Runtime

## Status

Normative. This specification replaces the earlier shell/chat integration
draft. There is one REPL contract for chat.el; language support is supplied by
adapters rather than by parallel user interfaces.

## Purpose

A developer can keep a language process alive beside a chat session, evaluate
several inputs against the same runtime state, observe bounded results, and
interrupt or replace that runtime without leaving the chat buffer.

The initial adapters are:

- `shell`, implemented by the system POSIX shell;
- `clojure`, implemented only by the official `clojure` CLI.

The adapter registry is public so another language can join without changing
the lifecycle, persistence, task, event, or UI contracts.

## Identity And Ownership

1. A REPL has a stable ID, one owning chat session ID, one adapter ID, one
   canonical working directory, and a monotonically increasing generation.
2. A chat session owns at most one selected REPL. A closed REPL is historical
   evidence and is never selected.
3. Runtime process handles, callbacks, parser fragments, and secrets are live
   memory only. They are never serialized.
4. REPL state and bounded transaction records live under `~/.chat/repl/`.
   Records from one chat session are not projected into another session.

## Lifecycle

The states are `starting`, `idle`, `busy`, `interrupted`, `failed`, and
`closed`.

- `start ADAPTER` creates a fresh identity and isolated process.
- `eval CODE` queues one transaction. Transactions for one REPL execute in
  submission order and never overlap.
- `interrupt` interrupts the active transaction. If the adapter or platform
  cannot prove that the process remained healthy, the REPL becomes
  `interrupted` and must be reset.
- `reset` terminates the complete old process tree, increments the generation,
  and starts a fresh process with the same identity, adapter, and directory.
- `close` terminates the complete process tree and makes the record terminal.
- Loading persisted `starting`, `idle`, or `busy` state after an application
  restart changes it to `interrupted`. Loading never starts a process and never
  repeats input.

There is no compatibility reader, legacy migration, backend fallback, hidden
retry, or automatic replay.

## Execution And Isolation

1. Every REPL process is started through `chat-execution` with policy `build`,
   network disabled, the working directory as its only project read/write
   root, an explicit environment, and mandatory process-tree cleanup.
2. Backend selection is capability based. If no installed backend can enforce
   the request, start fails explicitly; unrestricted local execution is not a
   fallback.
3. Adapter availability is checked before any durable active state is created.
4. Closing, resetting, cancellation, timeout, Emacs shutdown reconciliation,
   and abnormal process exit must not leave descendants behind.
5. Clojure starts with `clojure -Srepro`; project aliases and user dependency
   configuration are not loaded implicitly. The runtime is bound to the single
   bundled `clojure-tools` jar with `:local/root`, so network denial cannot turn
   startup into dependency resolution. No dependency manager other than the
   official CLI is part of this contract.

## Transactions And Output

1. Each input receives a stable transaction ID and a `chat-task` of kind
   `repl-eval`. The task owns a write resource keyed by the REPL ID, which
   serializes input without a second queue implementation.
2. Adapter framing uses an unguessable per-process token and transaction ID.
   Prompts and startup text are never used as completion signals.
3. A transaction records submitted time, terminal time, status, exit status,
   bounded code, bounded output, and whether either value was truncated.
4. Per-transaction code and output, retained transaction count, and emitted
   live chunks have independent configurable limits. Limits are enforced while
   streaming, not after accumulating an unbounded string.
5. A process exit with an active transaction fails that transaction and moves
   the REPL to `failed` or `interrupted`; it cannot be reported as successful.

## Chat Surface

The canonical command is `/repl`:

```text
/repl start shell
/repl start clojure
/repl eval CODE
/repl interrupt
/repl reset
/repl status
/repl adapters
/repl close
```

Starting a REPL claims plain input. While claimed, pressing Return evaluates
the input in the selected REPL; slash commands remain commands and `/auto`
returns plain input to normal chat. Explicit `/repl eval` works whether or not
plain input is claimed.

The prompt names the adapter and generation so an input line cannot look like a
model message. The input-adjacent work shelf shows one collapsed REPL section
only when the current chat session owns a non-closed REPL. It contains state,
adapter, directory, generation, active transaction, and recent bounded results.

Command hints remain passive and alphabetic/frequency ranked by the shared hint
system. They never capture selection or change Return semantics.

## Events

The runtime emits session-scoped events for creation, start, input queued,
input start, bounded output, input completion/failure/interruption, reset,
abnormal process exit, and close. Event payloads contain IDs and bounded
summaries, never environment values or unrestricted process output.

## Acceptance

1. Shell state survives two evaluations in one generation (`x=41`, then
   `echo $((x+1))`).
2. Official Clojure CLI state survives two evaluations (`def`, then use).
3. Two queued evaluations complete in submission order with distinct results.
4. Output beyond the configured limit is bounded and marked truncated.
5. A malformed input fails or terminates explicitly; it never completes from a
   prompt heuristic.
6. Restart reconciliation marks active records interrupted and starts nothing.
7. Reset and close leave no owned process or descendant alive.
8. A missing isolation backend or adapter executable fails closed.
9. Work-shelf projection is session scoped and disappears after close.
10. Unit, integration, and UI tests leave no background process and no compiler
    artifact in the repository.
