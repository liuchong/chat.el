# Dangerous Local Execution, Session Root Directory, While-Busy Default Release

- Type: stage-record
- Attention: active
- Status: implementation-verified
- Scope: approval modes, execution isolation, session directory model
- Date: 2026-09-03

## Trigger

A live session on the xgapi relay showed three independent defects at once: a
`/send` during `auto: /cmd` did not return plain input to the model; a guarded
session read "sandbox" refusals for `git fetch` and network with no way for the
user to say "allow everything for real"; and the model had no stable project
anchor because the only directory concept was the `/cd`-movable working
directory.

## Corrected Contracts

1. While-busy slash commands (`/send`, `/stage`, `/model`, ...) bypass
   `chat-ui--dispatch-command`, so they never ran `chat-ui--note-command-default`.
   An explicit `/send` now releases a claimed default back to the baseline, and
   `/stage` claims it, exactly as the non-busy path does.
2. `dangerous` approval mode now means complete consent: every model-directed
   execution path (`shell_execute`, background work / `programming_compile_task`,
   verification, REPL) runs on the unrestricted `local` execution backend
   (inherited environment, real HOME, network, no sandbox profile). `manual`
   and `guarded` keep `inspect` / `build`. The mode decides; a one-off human or
   guard consent never relaxes isolation. Specs 012 §2 and 023 Integrations/
   Acceptance revised.
3. A session now has two directories. The root directory (metadata
   `root-directory`) is pinned on first open -- falling back to the code
   session's project root, then the working directory -- and afterwards moves
   only through the new `/root` command. The working directory remains the
   `/cd`-movable current directory. Neither setter touches the other.
4. Every request injects a protected `session-directories` fragment naming both
   directories and their roles, with the standing rule that AGENTS.md in the
   root and in the current directory is required reading before changes.
   Project instruction graphs are collected from both directories and merged by
   fragment id, so shell work outside the root no longer drops the root's
   instructions. The agent run's default `project-root` is the session root.
   Spec 036 carries the contract.

## Verification

- Full ert suite: 2044 passed, 0 unexpected (2 pre-existing environment skips).
- Live smoke: dangerous+consent `echo $HOME` returned the real home
  `/Users/liu`; manual mode stayed on the gated sandbox path.
