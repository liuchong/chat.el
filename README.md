# chat.el

> ⚠️ **Alpha 阶段免责声明**
>
> 本项目尚处于早期测试阶段，核心功能仍在快速迭代中，**稳定性无法保证**。使用过程可能遇到功能缺陷、意外崩溃或数据丢失。
>
> 本项目采用**纯 AI 驱动开发**模式，代码由大语言模型生成并经人工审核，非传统人工编码方式。
>
> **欢迎体验测试**，但请知悉：测试期间产生的一切风险由使用者自行承担，项目方不对任何问题或损失负责。
>
> 🤝 **我们诚邀您参与**
> - 提交 Bug 反馈和功能建议
> - 贡献代码、文档或测试用例
> - 分享您的使用场景和痛点
> - 投入 Token、算力或时间支持项目发展
>
> 您的每一份贡献都将推动这个项目变得更好。

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

### Code Mode

A dedicated mode for software engineering with:

- **Smart Context** - Includes project structure, symbols, and project rules
- **Code Editing** - Explain, refactor, fix, document, and generate tests inline
- **Multi-file Refactoring** - Cross-file rename, extract to file, move functions
- **Test Integration** - Auto-detect test frameworks, run tests, auto-fix failures
- **Git Integration** - Review and analysis helpers remain available as experimental modules
- **LSP Integration** - Works with lsp-mode and eglot for enhanced context
- **Symbol Indexing** - Cross-references, call graph, related symbols
- **Streaming Responses** - Real-time code generation display

## Quick Start

Load the package:

```elisp
(add-to-list 'load-path "/path/to/chat.el")
(require 'chat)
```

Supported providers:

- `kimi`
- `kimi-code`
- `openai`
- `deepseek`
- `qwen`
- `grok`
- `claude`
- `gemini`
- `glm`
- `doubao`
- `hunyuan`
- `minimax`
- `mistral`

Configure providers in one of these files:

- `~/.chat.el`
- `~/.chat/config.el`
- `chat-config.local.el` in the repository root

Later files override earlier ones.

Minimal local config:

```elisp
(setq chat-default-model 'kimi)
(setq chat-llm-enabled-providers '(kimi openai deepseek qwen grok claude gemini))
(setq chat-llm-kimi-api-key "sk-kimi-...")
```

Or use `auth-source`:

```text
machine kimi-api user api-key password YOUR_KEY
machine claude-api user api-key password YOUR_KEY
machine gemini-api user api-key password YOUR_KEY
machine kimi-code-api user api-key password YOUR_KEY
machine openai-api user api-key password YOUR_KEY
```

Start a session:

```text
M-x chat
```

## Project Layout

```text
chat.el/
  chat.el
  chat-config.local.el.example
  lisp/
    core/
    llm/
    tools/
    ui/
    code/
  tests/
    unit/
    integration/
    prototypes/
    manual/
  scripts/
    maintenance/
    migration/
  docs/
  specs/
```

Layout rules:

- `chat.el` stays at the repository root as the single entry point
- runtime modules live under `lisp/` by domain
- stable regression tests live under `tests/unit/`
- exploratory scripts live under `tests/prototypes/` or `tests/manual/`
- one-off migration helpers live under `scripts/migration/`

## Common Commands

| Command | Purpose |
|---------|---------|
| `M-x chat` | Open or resume the current chat buffer |
| `M-x chat-new-session` | Create a new session |
| `M-x chat-list-sessions` | Switch to an existing session |
| `M-x chat-view-raw-message` | Inspect the last raw API exchange |
| `M-x chat-view-last-raw-exchange` | Open the latest assistant request and response |
| `M-x chat-ui-cancel-response` | Cancel the active response |
| `M-x chat-show-current-request-status` | Show the active request diagnostics buffer |

## Tool Model

Built in tools currently focus on coding assistance:

- `files_read`
- `files_read_lines`
- `open_file`
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
(setq chat-default-model 'kimi)
(setq chat-llm-enabled-providers
      '(kimi openai deepseek qwen grok claude gemini glm doubao hunyuan minimax mistral))
(setq chat-ui-use-streaming t)
(setq chat-session-auto-save t)
(setq chat-files-allowed-directories
      (list default-directory "/tmp/" "/var/tmp/"))
```

## Code Mode (AI Programming IDE)

chat.el includes a **Code Mode** for AI-assisted programming.
The current stable path is the single buffer code chat flow in `lisp/code/chat-code.el`.
Refactoring, git assistance, indexing extras, and performance helpers are still under repair and should be treated as experimental.

### Starting Code Mode

| Command | Description |
|---------|-------------|
| `M-x chat-code-start` | Start code mode for current project |
| `M-x chat-code-for-file` | Focus on specific file |
| `M-x chat-code-for-selection` | Use current selection as context |
| `M-x chat-code-quote-region` | Quote the active region into the code-mode input |
| `M-x chat-code-ask-region` | Ask AI about the active region immediately |

### Inline Editing Commands

| Command | Description |
|---------|-------------|
| `M-x chat-edit-explain` | Explain code at point |
| `M-x chat-edit-refactor` | Refactor with instruction |
| `M-x chat-edit-fix` | Fix code issues |
| `M-x chat-edit-docs` | Generate documentation |
| `M-x chat-edit-tests` | Generate unit tests |
| `M-x chat-edit-complete` | Complete code at point |

### Experimental Advanced Commands

These commands exist in the repository but are still being repaired and validated:

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
- **Streaming responses** - Real-time code generation toggle exists
- **Visible run state** - Header line shows running, success, failed, cancelled, or stopped
- **Structured request panel** - `C-c C-p` opens a dedicated panel for phases, approvals, tool calls, whitelist changes, and stalled-request context
- **Fast approval shortcuts** - pending approval prompts accept `C-c C-a` once, `C-c C-s` session, `C-c C-t` tool, `C-c C-c` command, and `C-c C-d` deny
- **Native prompt guidance** - approval prompts and pending-approval messages teach the same shortcut flow without inserting extra transcript noise
- **Persistent approval status** - pending approvals also surface in code mode `header-line` / mode line and in the chat buffer status line
- **Status discipline** - persistent status surfaces are reserved for blocking states; transient activity stays in the request panel or echo area
- **Detailed request diagnostics** - `C-c C-s` opens the full current-request status buffer
- **Project rooted guardrails** - Prompt and tool execution stay anchored to the active project root
- **Project rules in context** - `AGENTS.md` is injected into code mode context when present
- **LSP integration** - Optional integration points exist
- **Experimental modules** - Refactor, git, indexing extras, and perf helpers are under repair

See `specs/002-code-mode*.md` for detailed documentation.

## Architecture Map

| File | Responsibility |
|------|----------------|
| `chat.el` | Entry point and command wiring |
| `lisp/ui/chat-ui.el` | Chat buffer rendering and response lifecycle |
| `lisp/core/chat-session.el` | Session and message persistence |
| `lisp/llm/chat-llm.el` | Provider abstraction and async request handling |
| `lisp/core/chat-stream.el` | SSE parsing and chunk handling |
| `lisp/tools/chat-tool-caller.el` | Tool prompt contract, parsing, and execution |
| `lisp/core/chat-approval.el` | Approval flow for risky tools and tool creation |
| `lisp/core/chat-files.el` | Built in file tools and path safety checks |
| `lisp/core/chat-context.el` | Context trimming and summary generation |
| `lisp/tools/chat-tool-forge.el` | Tool registry, compilation, loading, and execution |
| `lisp/tools/chat-tool-forge-ai.el` | AI assisted tool generation flow |
| `lisp/code/chat-code.el` | Code mode main entry |
| `lisp/code/chat-context-code.el` | Smart context building |
| `lisp/code/chat-edit.el` | Edit operations |
| `lisp/code/chat-code-preview.el` | Preview buffer for changes |
| `lisp/code/chat-code-intel.el` | Symbol indexing and call graph |
| `lisp/code/chat-code-lsp.el` | LSP client integration |
| `lisp/code/chat-code-refactor.el` | Multi-file refactoring |
| `lisp/code/chat-code-test.el` | Test framework integration |
| `lisp/code/chat-code-git.el` | Git integration helpers |
| `lisp/code/chat-code-perf.el` | Performance and indexing helpers |

## Testing

Run the canonical test entry:

```bash
emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit
```

Current baseline:

- 205 regression tests discovered
- 205 passing
- 0 skipped in the canonical batch suite

Run provider integration tests separately:

```bash
emacs -Q -batch -l tests/run-integration-tests.el -f ert-run-tests-batch-and-exit
```

Integration test notes:

- requires real provider credentials
- currently includes the Kimi online request checks
- should be run explicitly instead of being mixed into the canonical regression suite

## Documentation Map

- `docs/README.md` for the document index
- `docs/PROJECT_STATUS.md` for the current status snapshot
- `docs/troubleshooting-pitfalls.md` for known issues and fixes
- `.agents/` for agent workflow records, decisions, logs, and stage history

## Notes For Contributors

- Read `AGENTS.md` before making changes
- Read `.agents/README.md`, `.agents/00-entry/current.md`, `.agents/00-entry/read-order.md`, `.agents/10-active/focus.md`, and `.agents/10-active/risks.md` before implementation work
- Update `.agents/` after each completed stage
- Add regression tests for each bug fix
- Do not use destructive git commands

## License

Copyright 2026 chat.el contributors.
This project is licensed under the [One Public License (1PL)](./LICENSE).
