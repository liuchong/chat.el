# Multimodal Content

Status: implemented
Date: 2026-08-28
Roadmap: M5
Decision: 0023

## Goal

Carry text, images and ordinary files through one typed message pipeline while
keeping old JSONL readable, binary data out of session history and provider
differences at the transport boundary.

## Content Contract

`chat-content-part` schema version 1 contains a type plus the fields required by
that type. Text owns `text`. Image and file parts own a durable attachment id,
display name, MIME type, byte size and SHA-256 digest. Reasoning, tool-call and
tool-result are reserved in the same vocabulary so later runtime projections do
not invent another content shape.

`chat-message.content` is the ordinary text projection and remains available to
all existing callers. `chat-message.content-parts` is optional. A missing field
normalizes from the old string; a present future schema fails explicitly.

## Attachment Store

`chat-attachment-directory` defaults to `~/.chat/attachments/`. Ingest checks a
regular file and the 25 MB default limit, copies a stable snapshot and addresses
that snapshot by its digest. Equal bytes deduplicate to one atomic payload at
`<sha256>/content`.

The session stores no source path. A reference must be a lowercase 64-character
SHA-256 equal to its declared digest. Resolution checks payload existence,
actual size, the current size limit and the payload digest before encoding or
preview. Display names cannot contain control characters.

## Provider Encoding

- OpenAI-compatible requests use ordered text and image URL parts with local
  image bytes represented as a data URL. Text files become named text blocks.
- Anthropic-compatible requests use text, base64 image sources and supported
  document sources. Text files and PDF documents retain their names.
- Gemini requests use text and inline data parts with MIME type and base64 data.
- Unknown or false input modality support fails before dispatch.
- An unsupported binary file produces an explicit adapter error; it is never
  omitted from the request silently.

Only user messages may carry input attachments in M5. Tool and reasoning data
continue to use their established ordered runtime records while sharing the
versioned content vocabulary.

## Native Input And Transcript

`C-c C-o` stages a file, `C-c C-y` stages a clipboard image and `C-c C-x`
removes a staged attachment. `M-x chat-ui-preview-attachment` previews staged or
recorded content. Compact rows above the input prompt show type, name and size
without changing the text editing region.

Sending records text and parts atomically. Empty text is allowed when at least
one attachment exists. Control commands leave staged attachments alone. During
an active run, insertion queues an attachment-bearing draft as a fresh turn;
queue preserves order and interrupt cancels before sending the replacement.

The transcript shows durable attachment references after reload without
exposing local paths. Edit-resend restores both text and non-text parts on the
new branch. Context budgeting counts text once, assigns a conservative image
cost and estimates files from bounded byte size.

## Persistence And Migration

Session format version 1 gains the additive `contentParts` field. Old records
load without a rewrite. New saves progressively write typed parts alongside the
same `content` text projection. Branch and compaction operate on message
objects, so surviving messages retain their part references without copying
binary bytes.

## Acceptance

- old text-only JSONL loads and sends unchanged;
- attachments survive save, reload, branch and edit-resend;
- attachment-only messages are valid;
- three offline provider fixtures preserve part order and MIME data;
- model capability mismatches fail before network dispatch;
- session files contain no absolute source path or embedded binary body;
- forged references and changed payload bytes fail closed;
- the canonical suite passes with no unexpected result.
