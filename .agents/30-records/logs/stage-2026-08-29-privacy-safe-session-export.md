# Stage: Privacy-Safe Session Export

- Type: log
- Attention: record
- Status: done
- Scope: project
- Date: 2026-08-29
- Tags: session, export, privacy, markdown, atomic-write

## What Changed

The active chat buffer and session tree now export a saved conversation as a
deterministic Markdown transcript.  The implementation lives in an independent
core module; UI surfaces only select the session and destination.

The exported form is deliberately narrower than session persistence.  It keeps
ordinary user and assistant text, stable session identity and lineage, model
identity, UTC timestamps, and bounded attachment display summaries.  It omits
system and tool messages, prompt stacks, reasoning, tool arguments and results,
raw provider traffic, attachment storage identifiers, approvals, working paths,
and arbitrary metadata.

Writes go through a same-directory temporary file and atomic rename.  Existing
destinations require explicit confirmation, and failed exports leave them
unchanged.

## Verification

- focused session-export contracts: 7/7 passed
- canonical ERT suite: 1817/1817 passed
- documentation command contracts: 4/4 passed
- Markdown, MDP and table tests remained green in the canonical run

## Reusable Lessons

A session export must start from an explicit public-field allowlist.  Redacting
the persistence object after serialization is fragile because every new private
field becomes a possible leak.  Project visible content directly instead.

Presentation and interchange also need separate paths.  Preserving stored
Markdown source avoids carrying Emacs text properties into files and avoids
destroying fences, tables, emphasis, or links through a second render cycle.

Atomicity and privacy are independent requirements.  A correctly redacted
transcript can still be harmful if a cancelled write truncates an existing
file, so same-directory temporary writes and explicit overwrite authority are
part of the export contract rather than UI polish.
