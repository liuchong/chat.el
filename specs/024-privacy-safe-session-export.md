# Privacy-Safe Session Export

Status: Implemented

## Purpose

Saved sessions contain two different kinds of information:

1. conversation content the developer intentionally saw;
2. private runtime state needed to continue or diagnose an agent run.

Exporting the persistence file would mix those boundaries.  The session export
therefore creates a versioned public projection instead of copying JSONL.

## User Workflows

- `M-x chat-export-session` exports the active chat session.
- `M-x chat-session-tree-open`, then `e`, exports the session at point.
- `chat-session-export-directory` selects the initial export directory.  A nil
  value follows the current buffer's `default-directory`.
- The suggested file name keeps useful Unicode title text, removes path-unsafe
  punctuation, collapses separators, and appends the stable session id.
- Selecting an existing destination requires explicit overwrite confirmation.

## Public Projection Contract

Schema version 1 is deterministic for a fixed session value.  Timestamps are
written in UTC.  The projection may contain only:

- session display name and id;
- provider and configured remote model name;
- created and updated timestamps;
- parent and branch identifiers when present;
- ordinary `:user` and `:assistant` text in stored order;
- attachment display name, media type, and byte size.

Message text is preserved as Markdown source.  It is not passed through the
display renderer, so fenced code, tables, emphasis, links, and other syntax do
not accumulate presentation properties or lose source markers.

The default projection must never contain:

- `:system` or `:tool` messages;
- prompt stacks or injected instructions;
- reasoning content;
- tool calls, arguments, results, or execution events;
- raw provider requests or responses;
- attachment paths, hashes, or payload bytes;
- approval modes, grants, or guard records;
- working directories or arbitrary session/message metadata.

This is a structural allowlist.  It does not claim to redact secrets that a
developer deliberately typed into visible user text or that an assistant
included in its visible answer.

## Write Contract

`chat-session-export-write` renders the complete public projection before the
destination changes.  It writes UTF-8 with Unix newlines to a same-directory
temporary file and then renames that file atomically.

- A missing destination directory is an error.
- An existing destination is an error unless overwrite is explicit.
- Any render or write failure removes the temporary file.
- A failed export leaves an existing destination byte-for-byte unchanged.

## Module Boundary

`lisp/core/chat-session-export.el` owns projection, naming, prompting, and
atomic persistence.  It depends only on the stable session and typed-content
APIs.  The chat buffer and session tree are adapters that supply a session;
they do not inspect private message fields or build Markdown themselves.

Machine-readable backups and full diagnostic archives are separate products.
They must not widen this public projection or reuse its command names without a
new versioned authorization and secrets-handling contract.

## Acceptance

The feature is accepted when automated tests prove all of the following:

1. visible user and assistant Markdown survives unchanged;
2. system, reasoning, tool, raw transport, path, and metadata fixtures do not
   appear anywhere in the output;
3. typed attachments produce bounded summaries without storage identifiers;
4. repeated projection of the same session is byte-identical;
5. Unicode titles produce portable file names;
6. existing files are not silently overwritten or partially changed;
7. the session-tree export key is installed and an empty row fails clearly;
8. the complete regression suite passes without Markdown, MDP, table, session,
   or UI regressions.
