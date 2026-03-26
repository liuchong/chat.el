# Code Mode Phase 3 Implementation

## Summary

This document records the intended Phase 3 scope.
Streaming support exists in the repository, but code intelligence, LSP integration, and related indexing features still require repair and validation.

## Features Implemented

### 1. Enhanced Symbol Indexing

**File:** `chat-code-intel.el`

**Features:**
- Multi-phase indexing (symbols → references → call graph)
- Cross-reference tracking
- Call graph analysis (callers and callees)
- Related symbol detection

**Key Functions:**
- `chat-code-intel-index-project` - Index with references
- `chat-code-intel-find-references` - Find all references
- `chat-code-intel-get-callers` - Get functions calling a symbol
- `chat-code-intel-get-callees` - Get functions called by a symbol
- `chat-code-intel-get-related-symbols` - Get related symbols (1-2 levels)

**Commands:**
- `chat-code-index-project` - Index current project
- `chat-code-find-symbol` - Find symbol definition
- `chat-code-find-references` - Find symbol references

### 2. Smart Context

**File:** `chat-context-code.el`

**Features:**
- Symbol-based context building
- Automatic related symbol inclusion
- Priority-based context ordering

**Implementation:**
- Uses symbol index to find related functions
- Adds related symbol information to context
- Integrates with existing context strategies

### 3. Streaming Response Support

**File:** `chat-code.el`

**Features:**
- Real-time code generation display
- Character-by-character streaming
- Configurable streaming toggle

**Configuration:**
```elisp
(setq chat-code-use-streaming t)  ; Enable streaming
```

**Key Functions:**
- `chat-code--send-streaming` - Send streaming request
- Streaming completion is finalized through the current `chat-code` response path

### 4. LSP Integration

**File:** `chat-code-lsp.el` (new)

**Features:**
- Auto-detect LSP client (lsp-mode or eglot)
- Get symbol information at point
- Get diagnostics (errors/warnings)
- Get hover documentation
- Format LSP context for LLM

**Functions:**
- `chat-code-lsp-get-symbol-at-point` - Symbol under cursor
- `chat-code-lsp-get-diagnostics` - File diagnostics
- `chat-code-lsp-get-context` - Complete LSP context
- `chat-code-lsp-format-context` - Format for LLM prompt

**Integration:**
- LSP context automatically added to system prompt
- Includes current symbol, diagnostics, and hover info
- Non-intrusive (works without LSP too)

## File Structure

```
chat-code.el              - Extended with streaming and LSP
chat-context-code.el      - Smart context with symbol support
chat-code-intel.el        - Enhanced symbol indexing
chat-code-lsp.el          - LSP integration (new)
chat-stream.el            - Streaming support (existing)
```

## Usage

### Enhanced Symbol Indexing

```elisp
;; Index project with cross-references
M-x chat-code-index-project

;; Find all references to a function
M-x chat-code-find-references
Symbol name: my-function

;; Get related symbols automatically in context
M-x chat-code-start
> Refactor the connect function
;; Context automatically includes callers and callees
```

### Streaming Responses

```elisp
;; Enable streaming (default)
(setq chat-code-use-streaming t)

;; In code mode, you'll see response appear character by character
M-x chat-code-start
> Write a factorial function
;; Watch code appear in real-time
```

### LSP Integration

```elisp
;; If lsp-mode or eglot is active, context automatically includes:
;; - Current symbol under cursor
;; - Diagnostics (errors/warnings)
;; - Hover documentation

M-x chat-code-for-file
;; LSP info automatically added to context
```

## Testing

```bash
cd /path/to/chat.el
emacs -Q -batch -l test-code-mode.el
```

Use `tests/run-tests.el` and current unit tests to verify present behavior.
This phase note is not the source of truth for current test status.

## Next Steps (Phase 4)

1. **Multi-file Refactoring**
   - Cross-file rename
   - Extract to new file
   - Move function between files

2. **Test Integration**
   - Run tests after code changes
   - Auto-fix failing tests
   - Test coverage analysis

3. **Git Integration**
   - Use git diff as context
   - Suggest commit messages
   - Review changes before apply

4. **Performance Optimization**
   - Incremental indexing
   - Background indexing
   - Cache invalidation

---

*Phase 3 Notes - historical record*
