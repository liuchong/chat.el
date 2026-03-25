# chat.el

[![License: 1PL](https://img.shields.io/badge/License-1PL-blue.svg)](https://license.pub/1pl/)

`chat.el` is a pure Emacs AI chat client focused on coding workflows.
It supports multi turn chat, tool calling, file operations, session persistence, context trimming, streaming display, and AI assisted tool forging.


Copyright 2026 chat.el contributors.

## License

This project is licensed under the [One Public License (1PL)](https://license.pub/1pl/).
See the [LICENSE](./LICENSE) file for the full license text.

1PL is a copyleft license that ensures when you distribute this software or derivative
works, the complete source code must be made available under the same license terms.

## Current Capabilities

- Chat with Kimi, Kimi Code, and OpenAI compatible providers
- Keep multiple sessions on disk and inspect raw request and response data
- Stream or fetch responses through an async non blocking UI path
- Expose built in file tools with approval gates for risky operations
- Feed tool results back into the model through a bounded tool loop
- Trim long conversations with system message preservation and summary messages
- Generate custom tools and save them to disk after explicit approval

### Code Mode (AI Programming IDE)

A dedicated mode for software engineering with:

- **Smart Context** - Automatically includes project structure, symbols, git status
- **Code Editing** - Explain, refactor, fix, document, and generate tests inline
- **Multi-file Refactoring** - Cross-file rename, extract to file, move functions
- **Test Integration** - Auto-detect test frameworks, run tests, auto-fix failures
- **Git Integration** - AI-suggested commit messages, pre-commit checks, code review
- **LSP Integration** - Works with lsp-mode and eglot for enhanced context
- **Symbol Indexing** - Cross-references, call graph, related symbols
- **Streaming Responses** - Real-time code generation display

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

## Code Mode (AI Programming IDE)

chat.el includes a comprehensive **Code Mode** for AI-assisted programming:

### Starting Code Mode

| Command | Description |
|---------|-------------|
| `M-x chat-code-start` | Start code mode for current project |
| `M-x chat-code-for-file` | Focus on specific file |
| `M-x chat-code-for-selection` | Use current selection as context |

### Inline Editing Commands

| Command | Description |
|---------|-------------|
| `M-x chat-edit-explain` | Explain code at point |
| `M-x chat-edit-refactor` | Refactor with instruction |
| `M-x chat-edit-fix` | Fix code issues |
| `M-x chat-edit-docs` | Generate documentation |
| `M-x chat-edit-tests` | Generate unit tests |
| `M-x chat-edit-complete` | Complete code at point |

### Multi-file Refactoring

| Command | Description |
|---------|-------------|
| `M-x chat-code-rename-symbol` | Rename symbol across project |
| `M-x chat-code-extract-to-file` | Extract code to new file |
| `M-x chat-code-move-function` | Move function between files |

### Test Integration

| Command | Description |
|---------|-------------|
| `M-x chat-code-run-tests` | Run tests for current file |
| `M-x chat-code-test-generate` | Generate tests for function |
| `M-x chat-code-test-coverage-current` | Show test coverage |

### Git Integration

| Command | Description |
|---------|-------------|
| `M-x chat-code-git-commit-suggest` | AI-suggested commit message |
| `M-x chat-code-git-review` | Review changes with AI |
| `M-x chat-code-git-pre-commit` | Run pre-commit checks |

### Code Intelligence

| Command | Description |
|---------|-------------|
| `M-x chat-code-index-project` | Index project symbols |
| `M-x chat-code-find-symbol` | Find symbol definition |
| `M-x chat-code-find-references` | Find symbol references |
| `M-x chat-code-incremental-index` | Update index incrementally |

### Code Mode Features

- **Single-window design** - Respects your window layout
- **4 context strategies** - minimal, focused, balanced, comprehensive
- **Symbol indexing** - Cross-references and call graph analysis
- **LSP integration** - Works with lsp-mode and eglot
- **Streaming responses** - Real-time code generation
- **Git diff context** - Automatic inclusion of uncommitted changes
- **Performance** - Incremental indexing and background updates

See `specs/002-code-mode*.md` for detailed documentation.

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
| `chat-code.el` | Code mode main entry |
| `chat-context-code.el` | Smart context building |
| `chat-edit.el` | Edit operations |
| `chat-code-preview.el` | Preview buffer for changes |
| `chat-code-intel.el` | Symbol indexing and call graph |
| `chat-code-lsp.el` | LSP client integration |
| `chat-code-refactor.el` | Multi-file refactoring |
| `chat-code-test.el` | Test framework integration |
| `chat-code-git.el` | Git integration |
| `chat-code-perf.el` | Performance optimization |

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

## License

This project is licensed under the [One Public License (1PL)](./LICENSE).
