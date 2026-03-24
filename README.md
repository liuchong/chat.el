# chat.el

A pure Emacs AI chat client with Kimi integration.

## Features

- **Multiple chat sessions** - Manage separate conversations
- **Session persistence** - Auto-saved to ~/.chat/sessions/
- **Kimi AI integration** - Powered by Moonshot AI
- **File operations** - AI can read and work with your files
- **Pure Emacs Lisp** - No external dependencies

## Quick Start

1. Clone and add to load path:
```elisp
(add-to-list 'load-path "~/path/to/chat.el")
(require 'chat)
```

2. Configure your Kimi API key in `chat-config.local.el`:
```elisp
(setq chat-llm-kimi-api-key "your-api-key")
(setq chat-default-model 'kimi)
```

3. Start chatting:
```
M-x chat
```

## Commands

| Command | Description |
|---------|-------------|
| `M-x chat` | Start or resume a session |
| `M-x chat-new-session` | Create new chat session |
| `M-x chat-list-sessions` | List all saved sessions |

In chat buffer:
- Type your message after the `>` prompt
- Press `RET` to send
- AI response appears below

## Configuration

### API Key Setup

Create `chat-config.local.el` in the chat.el directory:

```elisp
(setq chat-llm-kimi-api-key "sk-...")
```

Or use auth-source (more secure):

Add to `~/.authinfo.gpg`:
```
machine kimi-api user api-key password YOUR_API_KEY
```

### Customization

```elisp
;; Default model
(setq chat-default-model 'kimi)

;; Session storage location
(setq chat-session-directory "~/.chat/sessions/")

;; Auto-save sessions
(setq chat-auto-save t)
```

## Development

Run tests:
```bash
./tests/run-tests.sh
```

Tested on Emacs 27+.

## Architecture

```
chat.el (main entry)
├── chat-session.el    (session management)
├── chat-files.el      (file operations)
├── chat-llm.el        (LLM abstraction)
├── chat-llm-kimi.el   (Kimi provider)
└── chat-ui.el         (UI components)
```

## License

Copyright 2026 chat.el contributors
