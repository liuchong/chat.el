# Stage: Multimodal Content

- Type: logs
- Attention: records
- Status: complete
- Scope: agent-runtime
- Tags: content, attachments, multimodal, persistence, providers, ui

Date: 2026-08-28
Spec: 014, 017
Decision: 0023

## Result

M5 adds `chat-content-part` version 1 without removing the established message
text field. Images and files live in a bounded content-addressed attachment
store, while session JSONL carries versioned references and the ordinary text
projection. Old sessions normalize to typed text when read and gain the new
field only through later saves.

The model runtime now validates input modalities before transport. Three
provider adapters translate the same ordered parts into their native image,
document or inline-data shapes. Text files degrade to named prompt blocks where
that is the portable representation; unsupported binary input fails visibly.

The native input surface stages files and clipboard images above the prompt,
supports removal and preview, accepts attachment-only turns and preserves parts
through active-run queue or interrupt behavior. Reloaded transcripts identify
attachments, edit-resend restores them on the new branch and context budgeting
no longer treats non-text input as free.

## Correctness Details

- Binary bytes never enter session JSONL or lifecycle event payloads.
- Attachment ids are exact SHA-256 values, so a session cannot traverse outside
  the store.
- Payload resolution checks size and digest before handing bytes to a provider.
- Equal payloads deduplicate and writes enter the store atomically.
- Control commands do not consume staged attachments.
- Text replacement preserves non-text parts.
- Unknown and unsupported model modalities differ and both produce useful
  preflight failures.
- Provider-specific request shapes do not leak into the core message contract.
- No attachment is silently dropped.

## Verification

The canonical suite passes 1466/1466 with zero unexpected results. New tests
cover schemas, legacy normalization, durable storage, size limits, forged
references, digest integrity, session round trips, provider fixtures, capability
preflight, prompt staging, attachment-only sends, command retention, queue and
interrupt semantics, transcript replay, edit-resend, compaction and token
estimates.

All commands ran in the foreground under the repository memory cap. No server
or background process was started.

## Next Stage

M6 adds checkpointed code recovery, optional worktree ownership and a unified
execution backend without weakening the distinction between durable intent and
live processes.
