# chat.el

A pure Emacs AI executor inspired by OpenClaw.

## Features

- Session management for multiple conversations
- File operations for AI tool use
- Extensible architecture for LLM providers

## Installation

Clone this repository and add to your load path:

```elisp
(add-to-list 'load-path "~/path/to/chat.el")
(require 'chat)
```

## Configuration

### Kimi API Setup

1. Get your API key from https://platform.moonshot.cn/

2. Create `chat-config.local.el` in the chat.el directory:

```elisp
(setq chat-llm-kimi-api-key "your-api-key-here")
(setq chat-default-model 'kimi)
```

3. Or use auth-source (recommended). Add to `~/.authinfo.gpg`:

```
machine kimi-api user api-key password YOUR_API_KEY
```

## Usage

Start a chat session:
```
M-x chat
```

Create a new session:
```
M-x chat-new-session
```

List all sessions:
```
M-x chat-list-sessions
```

## Development

Run tests:
```bash
./tests/run-tests.sh
```

## License

Copyright 2026 chat.el contributors
