# Code Mode Implementation Status

## Overview

This document records the original Phase 1 target.
The current repository has moved beyond the Phase 1 skeleton, but the implementation is still under repair and should not be treated as fully complete.

## Implemented Files

| File | Status | Description |
|------|--------|-------------|
| `chat-code.el` | ✅ Complete | Main entry point, session management, UI |
| `chat-context-code.el` | ✅ Complete | Context building with 4 strategies |
| `chat-edit.el` | ✅ Complete | Edit operations (generate, patch, rewrite, insert, delete) |
| `chat-code-preview.el` | ⚠️ Under repair | Preview buffer exists but integration is being repaired |
| `chat.el` integration | ✅ Complete | Auto-load code mode modules |

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         chat-code.el                             │
│  - Session management (chat-code-session)                        │
│  - Entry points (chat-code-start, chat-code-for-file, etc.)      │
│  - UI buffer (*chat:code:<session>*)                             │
│  - Single-window design, no forced splits                        │
└────────────────────────┬────────────────────────────────────────┘
                         │
         ┌───────────────┼───────────────┐
         │               │               │
         v               v               v
┌────────────────┐ ┌──────────────┐ ┌──────────────────┐
│chat-context-   │ │ chat-edit.el │ │chat-code-preview │
│code.el         │ │              │ │.el               │
│                │ │ - Edit ops   │ │                  │
│ - 4 strategies │ │ - Atomicity  │ │ - Diff view      │
│ - Token mgmt   │ │ - Backups    │ │ - Accept/Reject  │
│ - File context │ │ - History    │ │ - User control   │
└────────────────┘ └──────────────┘ └──────────────────┘
```

## Features Implemented

### 1. Session Management (chat-code.el)

**Entry Points:**
- `chat-code-start` - Start from current project
- `chat-code-for-file` - Focus on specific file
- `chat-code-for-selection` - Use current selection
- `chat-code-from-chat` - Convert existing chat

**Session Types:**
- Project root detection via `project.el`
- Focus file tracking
- Context strategy selection
- Language detection from file extension

**UI:**
- Single buffer design (`*chat:code:<session>*`)
- Header with project info, strategy, context
- Input area at bottom
- Message history

### 2. Context Management (chat-context-code.el)

**Strategies:**
- `minimal` - Current file only (~2k tokens)
- `focused` - Current + related files (~4k tokens)
- `balanced` - + imports + symbols (~8k tokens)
- `comprehensive` - Full project structure (~16k tokens)

**Context Sources:**
- File content (full or truncated)
- Import statements
- Symbol definitions
- Project structure
- Git status (placeholder)

**Token Management:**
- Automatic token estimation (~4 chars/token)
- Budget enforcement
- Priority-based truncation
- Smart content optimization

### 3. Edit Operations (chat-edit.el)

**Edit Types:**
- `generate` - Create new file
- `patch` - Modify specific line range
- `rewrite` - Replace entire file
- `insert` - Insert at position
- `delete` - Remove line range

**Safety Features:**
- Atomic application (all-or-nothing)
- Automatic backups
- Undo support
- File buffer refresh
- Validation before apply

**History:**
- Edit tracking
- Undo last edit
- View history

### 4. Preview (chat-code-preview.el)

**Design:**
- Separate buffer (`*chat-preview*`)
- No forced window splits
- User switches manually
- Diff-mode for syntax highlighting

**Commands:**
- `a` - Accept changes
- `r` - Reject changes
- `q` - Quit preview
- `n/p` - Navigate changes

## Keybindings

### Code Mode Buffer (`*chat:code:<session>*`)

| Key | Command | Description |
|-----|---------|-------------|
| `RET` | `chat-code-send-message` | Send message |
| `C-c C-a` | `chat-code-accept-last-edit` | Accept edit |
| `C-c C-k` | `chat-code-reject-last-edit` | Reject edit |
| `C-c C-v` | `chat-code-view-preview` | View preview |
| `C-c C-f` | `chat-code-focus-file` | Change focus |
| `C-c C-r` | `chat-code-refresh-context` | Refresh context |

### Preview Buffer (`*chat-preview*`)

| Key | Command | Description |
|-----|---------|-------------|
| `a` | `chat-code-preview-accept` | Accept changes |
| `r` | `chat-code-preview-reject` | Reject changes |
| `q` | `chat-code-preview-quit` | Close preview |
| `n` | `chat-code-preview-next-change` | Next change |
| `p` | `chat-code-preview-previous-change` | Previous change |

## Usage Example

```elisp
;; Start code mode for current project
M-x chat-code-start

;; Or start for specific file
M-x chat-code-for-file

;; Type your request
> Add error handling to the connect function

;; AI generates code, shows options:
;; [Apply: C-c C-a] [Preview: C-c C-v] [Reject: C-c C-k]

;; Option 1: Direct accept
C-c C-a

;; Option 2: Preview first
C-c C-v        ;; Switch to *chat-preview*
a              ;; Accept in preview buffer

;; Option 3: Manual buffer switch
C-x b *chat-preview* RET
;; Review, then 'a' to accept or 'r' to reject
```

## Testing

Canonical test entry:

```bash
cd /path/to/chat.el
emacs -Q -batch -l test-code-mode.el
```

This phase document is historical.
Current regression truth should be checked with `tests/unit/test-chat-code.el` and the full `tests/run-tests.el` batch run.

## Notes For Current Repair

1. The core chat path now exists in `chat-code.el`.
2. This document should not be used as the sole source of current feature status.
3. Missing or unstable features are documented in newer repair notes and current specs.

## Design Decisions

### Single Window Principle

**Rationale:** Emacs users prefer controlling their own window layout. Forced splits disrupt workflow.

**Implementation:**
- All operations in single buffer
- Preview in separate buffer, manually switched
- No `pop-to-buffer` with window splitting
- Standard `C-x b` for buffer switching

### Context Strategies

**Rationale:** Token limits require intelligent context selection.

**Implementation:**
- 4 predefined strategies
- Automatic budget management
- Priority-based truncation
- User can switch strategies mid-session

### Atomic Edits

**Rationale:** Code changes should be all-or-nothing to prevent broken states.

**Implementation:**
- Write to temp file first
- Atomic rename
- Backup before change
- Automatic undo support

---

*Implementation Version: 0.2*
*Date: 2026-03-26*
*Status: Historical Phase 1 Record*
