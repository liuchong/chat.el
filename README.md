# chat.el

`chat.el` is a pure Emacs AI chat client focused on coding workflows.
It supports multi turn chat, tool calling, file operations, session persistence, context trimming, streaming display, and AI assisted tool forging.


Copyright 2026 chat.el contributors.

## Current Capabilities

- Chat with Kimi, Kimi Code, and OpenAI compatible providers
- Keep multiple sessions on disk and inspect raw request and response data
- Stream or fetch responses through an async non blocking UI path
- Expose built in file tools with approval gates for risky operations
- Feed tool results back into the model through a bounded tool loop
- Trim long conversations with system message preservation and summary messages
- Generate custom tools and save them to disk after explicit approval

## Quick Start

Load the package:

```elisp
(add-to-list 'load-path "/path/to/chat.el")
(require 'chat)
```

Configure one provider:

```elisp
(setq chat-default-model 'kimi-code)
(setq chat-llm-kimi-code-api-key "sk-kimi-...")
```

Or use `auth-source`:

```text
machine kimi-code-api user api-key password YOUR_KEY
machine openai-api user api-key password YOUR_KEY
```

Start a session:

```text
M-x chat
```

## Common Commands

| Command | Purpose |
|---------|---------|
| `M-x chat` | Open or resume the current chat buffer |
| `M-x chat-new-session` | Create a new session |
| `M-x chat-list-sessions` | Switch to an existing session |
| `M-x chat-view-raw-message` | Inspect the last raw API exchange |
| `M-x chat-view-last-raw-exchange` | Open the latest assistant request and response |
| `M-x chat-ui-cancel-response` | Cancel the active response |

## Tool Model

Built in tools currently focus on coding assistance:

- `files_read`
- `files_read_lines`
- `files_list`
- `files_grep`
- `files_write`
- `files_replace`
- `files_patch`
- `apply_patch`

Risky tools require approval before execution.
Generated tools also require approval before registration.

Generated elisp tools must be a single top level `lambda` form.
This prevents compile time side effects from arbitrary wrapper forms.

## File Access Defaults

By default file tools can access:

- the current project directory
- `/tmp/`
- `/var/tmp/`

You can override this with `chat-files-allowed-directories`.

## Recommended Local Config

```elisp
(setq chat-default-model 'kimi-code)
(setq chat-ui-use-streaming t)
(setq chat-session-auto-save t)
(setq chat-files-allowed-directories
      (list default-directory "/tmp/" "/var/tmp/"))
```

## Architecture Map

| File | Responsibility |
|------|----------------|
| `chat.el` | Entry point and command wiring |
| `chat-ui.el` | Chat buffer rendering and response lifecycle |
| `chat-session.el` | Session and message persistence |
| `chat-llm.el` | Provider abstraction and async request handling |
| `chat-stream.el` | SSE parsing and chunk handling |
| `chat-tool-caller.el` | Tool prompt contract, parsing, and execution |
| `chat-approval.el` | Approval flow for risky tools and tool creation |
| `chat-files.el` | Built in file tools and path safety checks |
| `chat-context.el` | Context trimming and summary generation |
| `chat-tool-forge.el` | Tool registry, compilation, loading, and execution |
| `chat-tool-forge-ai.el` | AI assisted tool generation flow |

## Testing

Run the canonical test entry:

```bash
emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit
```

Current baseline:

- 122 tests discovered
- 120 passing
- 2 skipped provider integration tests

## Documentation Map

- `docs/README.md` for the document index
- `docs/PROJECT_STATUS.md` for the current status snapshot
- `docs/troubleshooting-pitfalls.md` for known issues and fixes
- `docs/ai-contexts/` for session records and implementation history

## Notes For Contributors

- Read `AGENTS.md` before making changes
- Update `docs/ai-contexts/` after each development session
- Add regression tests for each bug fix
- Do not use destructive git commands or create commits from AI
