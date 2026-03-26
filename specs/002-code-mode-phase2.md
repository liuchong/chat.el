# Code Mode Phase 2 Implementation

## Summary

This document records the intended Phase 2 scope.
Several items listed here exist in the repository, but they should not be treated as fully verified completion status.

### 1. LLM Integration ✅

**File:** `chat-code.el`

- Async LLM requests via `chat-llm-request-async`
- Context building before each request
- Response handling with code edit detection
- Error handling

**Key Functions:**
- `chat-code--send-to-llm` - Send message with context
- `chat-code--handle-llm-response` - Process AI response
- `chat-code--parse-code-edit` - Detect code suggestions

### 2. Inline Editing Commands ✅

**File:** `chat-code.el`

Available commands for direct use in code buffers:

| Command | Description |
|---------|-------------|
| `chat-edit-explain` | Explain code at point/selection |
| `chat-edit-refactor` | Refactor code with instruction |
| `chat-edit-fix` | Fix issues in code |
| `chat-edit-docs` | Generate documentation |
| `chat-edit-tests` | Generate tests |
| `chat-edit-complete` | Complete code at point |

**Usage:**
```elisp
;; In a code buffer, select function and:
M-x chat-edit-explain

;; Or with custom instruction:
M-x chat-edit-refactor
Refactor instruction: Extract this into a helper function
```

### 3. Code Intelligence ✅

**File:** `chat-code-intel.el`

Basic symbol indexing:
- Language detection (Python, JS, Elisp, Go, Rust, etc.)
- Symbol extraction (functions, classes, variables)
- Initial index persistence hooks
- Project indexing command

**Commands:**
- `chat-code-index-project` - Index current project
- `chat-code-find-symbol` - Find symbol in project

### 4. Edit Workflow ✅

**Files:** `chat-code.el`, `chat-edit.el`, `chat-code-preview.el`

Intended edit workflow:
1. AI suggests code change
2. Edit stored in `chat-code--pending-edit`
3. User options displayed: [Apply] [Preview] [Reject]
4. Auto-apply if change is small (< `chat-code-auto-apply-threshold`)
5. Manual accept/reject with `C-c C-a` / `C-c C-k`
6. Preview with `C-c C-v` when preview integration is available

## Files Added/Modified

```
chat.el                  - Load code mode modules
chat-code.el             - Main code mode (extended)
chat-context-code.el     - Context building
chat-edit.el             - Edit operations
chat-code-preview.el     - Preview buffer
chat-code-intel.el       - Code intelligence (new, simplified)
test-code-mode.el        - Test suite
```

## Usage Example

```elisp
;; Start code mode
M-x chat-code-start

;; Or for specific file
M-x chat-code-for-file

;; In the chat buffer:
> Add error handling to the connect function

;; AI responds with code change
;; Options: C-c C-a (accept), C-c C-v (preview), C-c C-k (reject)

;; Or use inline editing from code buffer:
M-x chat-edit-explain     ; Explain selected code
M-x chat-edit-fix         ; Fix issues
M-x chat-edit-tests       ; Generate tests
```

## Testing

```bash
cd /path/to/chat.el
emacs -Q -batch -l test-code-mode.el
```

Use the canonical batch entry `tests/run-tests.el` to verify current state.
Do not treat this phase note as the source of truth for present test status.

## Next Steps (Phase 3)

1. **Enhanced Symbol Indexing**
   - Cross-references
   - Call graph
   - Type information

2. **Smart Context**
   - Import resolution
   - Related file detection
   - Symbol-based context

3. **Streaming Responses**
   - Real-time code generation
   - Progress indicators

4. **Tool Integration**
   - LSP integration
   - Git diff context
   - Error/diagnostic context

---

*Phase 2 Notes - historical record*
