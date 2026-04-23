# Decision 0002

- Type: decisions
- Attention: reference
- Status: accepted
- Scope: protocol
- Tags: json, tool-calling, prompt, protocol

## Title

Use JSON as the only formal machine-readable protocol format

## Context

Early `chat.el` history included XML-style tool calling experiments. Later stages standardized on JSON for tool calls, approvals, patch payloads, and other machine-readable exchanges.

## Decision

- Require JSON for all structured request and response formats
- Reject XML, YAML, custom tags, and natural-language pseudo-structures as formal protocol replacements
- Keep prompt and parser design aligned with the JSON-only rule

## Consequences

- Tool calling, approvals, and editing flows share one structured contract family
- Tests can validate one concrete parsing model
- Historical XML-based records are retained only as legacy logs, not as current guidance
