# Decision 0023

- Type: decisions
- Attention: reference
- Status: accepted
- Scope: agent-runtime
- Tags: content, attachments, multimodal, persistence, providers

## Title

Keep message text as a compatibility projection over typed durable content

## Context

Session messages stored one string even when a provider request needed an
image, document or another structured block. Embedding binary data directly in
JSONL would make every save, branch and compaction copy an unbounded payload.
Replacing the string field outright would also break old sessions, transcript
code, hooks and tools that correctly depend on ordinary message text.

Provider request formats differ at the wire boundary, but those differences
must not become three core message models. A session also cannot be allowed to
turn a stored attachment reference into an arbitrary local file read.

## Decision

`chat-content-part` version 1 is the canonical content contract. It supports
text, image, file, reasoning, tool-call and tool-result types. The first M5 UI
supports text, images and ordinary files; the remaining types reserve one
versioned vocabulary for runtime records and later transport work.

`chat-message.content` remains the stable text projection. The optional
`contentParts` JSON field is additive: old JSONL reads as one text part, while
new saves write both the projection and typed parts. Editing text replaces only
text parts and preserves attachments.

Binary bytes live under `~/.chat/attachments/`, addressed by lowercase SHA-256.
Session records store the digest, display name, MIME type, size and schema
version, never an absolute source path or base64 body. Attachment ids must be
exactly 64 hexadecimal characters and equal the declared digest. Resolving a
payload verifies that its actual size matches the record and remains under the
configured limit, then verifies the stored bytes against the digest. Ingest
addresses a copied snapshot so a changing source cannot split hashing from
storage.

The model runtime computes required input modalities from parts and rejects a
known unsupported request before transport. Text files become named text
blocks. Provider adapters translate images and supported documents only at the
wire boundary. No adapter may silently discard a part.

The chat input owns a staged attachment list beside editable text. File attach,
clipboard image, preview and removal are native commands. A textless attachment
is a valid user turn. During an active run, ordinary insertion queues an
attachment-bearing draft as the next turn; explicit interrupt cancels first and
then sends it. Queued drafts preserve typed parts.

## Consequences

Existing sessions and text-only code retain their behavior while new sessions
can survive restart, branch, edit-resend and compaction with durable attachment
references. Provider-specific JSON stays isolated in provider modules. Session
files remain small and inspectable, and forged path traversal references fail
before any file is opened.

The content-addressed store intentionally keeps unreferenced payloads in M5.
Garbage collection needs a repository-wide reachability pass and is deferred
until retention policy is explicit. Audio, video, remote upload APIs and inline
transcript thumbnails are also outside this first version.

## Verification

The canonical suite passes 1466/1466. Focused fixtures cover the three provider
wire shapes, capability preflight, legacy text migration, restart persistence,
branch/edit recovery, compaction, attachment-only sends, active-run queue and
interrupt semantics, size limits, digest integrity and path traversal rejection.
