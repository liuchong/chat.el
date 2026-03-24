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
