# chat.el

A self-evolving AI chat client for Emacs with tool forging capabilities.

## Features

- **🤖 Multiple AI Providers** - Kimi (Moonshot) and OpenAI support
- **⚡ Streaming Responses** - Real-time typing effect
- **🛠️ Tool Forging** - AI creates custom tools that persist and evolve
- **💾 Session Management** - Multiple conversations with persistence
- **📁 File Operations** - AI can read, search, and modify files
- **🔄 Self-Evolution** - System capabilities grow through use

## Quick Start

1. Clone and load:
```elisp
(add-to-list 'load-path "~/path/to/chat.el")
(require 'chat)
```

2. Configure API key in `chat-config.local.el`:
```elisp
(setq chat-llm-kimi-api-key "your-api-key")
(setq chat-default-model 'kimi)
```

3. Start chatting:
```
M-x chat
```

## Tool Forging (Self-Evolution)

The killer feature: AI can create new tools for you.

### Creating a Tool

In chat, simply say:
```
Create a tool that counts words in text
```

The AI will:
1. Generate Emacs Lisp code
2. Compile and test it
3. Register the tool
4. Save it to `~/.chat/tools/`

### Using Created Tools

```elisp
;; Execute a forged tool
(chat-tool-forge-execute 'word-counter "your text here")

;; List all available tools
(chat-tool-forge-list)

;; See tool details
(chat-tool-forge-get 'word-counter)
```

### Tool Storage

Tools are saved as plain Emacs Lisp files in `~/.chat/tools/`:
```elisp
;;; chat-tool: word-counter
;;; name: Word Counter
;;; description: Count words in text
;;; language: elisp

(lambda (text)
  "Count words in TEXT."
  (length (split-string text)))
```

Tools auto-load on startup and persist across sessions.

## Commands

| Command | Description |
|---------|-------------|
| `M-x chat` | Start or resume chat |
| `M-x chat-new-session` | Create new session |
| `M-x chat-list-sessions` | List all sessions |
| `M-x chat-tool-forge-list` | List forged tools |

In chat buffer:
- Type message after `>` and press `RET` to send
- Type "Create a tool that..." to forge new tools
- AI responds with streaming text display

## Configuration

### API Keys

Create `chat-config.local.el`:
```elisp
;; For Kimi (Moonshot)
(setq chat-llm-kimi-api-key "sk-...")

;; For OpenAI (optional)
(setq chat-llm-openai-api-key "sk-...")

;; Default model
(setq chat-default-model 'kimi)  ; or 'openai
```

Or use auth-source (secure):
```
# ~/.authinfo.gpg
machine kimi-api user api-key password YOUR_KEY
machine openai-api user api-key password YOUR_KEY
```

### Customization

```elisp
;; Session storage
(setq chat-session-directory "~/.chat/sessions/")

;; Tool storage
(setq chat-tool-forge-directory "~/.chat/tools/")

;; Auto-save
(setq chat-auto-save t)
```

## Architecture

```
chat.el
├── Core
│   ├── chat-session.el      ; Session persistence
│   ├── chat-files.el        ; File operations
│   └── chat-ui.el           ; Interactive UI
├── LLM
│   ├── chat-llm.el          ; Provider abstraction
│   ├── chat-llm-kimi.el     ; Kimi provider
│   ├── chat-llm-openai.el   ; OpenAI provider
│   └── chat-stream.el       ; Streaming display
└── Tool Forge (Self-Evolution)
    ├── chat-tool-forge.el     ; Tool management
    └── chat-tool-forge-ai.el  ; AI tool generation
```

## Development

Run tests:
```bash
./tests/run-tests.sh
```

57 tests covering all modules.

## How It Works

### Tool Generation Flow

1. **User Request** → "Create a tool that X"
2. **Tool Request Detection** → chat-tool-forge-ai detects trigger phrase
3. **Prompt Engineering** → Build prompt with existing tools context
4. **Code Generation** → LLM generates Emacs Lisp lambda
5. **Compilation** → Code is compiled and validated
6. **Registration** → Tool added to in-memory registry
7. **Persistence** → Tool saved to disk for future sessions
8. **Confirmation** → User sees "✅ Tool 'Name' created"

### Example Tool Evolution

```
User: Create a tool that extracts URLs from text

AI: ✅ Tool 'URL Extractor' (url-extractor) created!

User: (later) Create a tool that downloads URLs

AI: ✅ Tool 'URL Downloader' (url-downloader) created!
    (AI knows about url-extractor and may use it)
```

## License

Copyright 2026 chat.el contributors

## Acknowledgments

Inspired by OpenClaw's self-evolving architecture, implemented purely in Emacs Lisp.
