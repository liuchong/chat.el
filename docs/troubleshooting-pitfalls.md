# Troubleshooting and Pitfalls

This document records known issues and their solutions for chat.el development.

---

## API Authentication Errors

### 401 Invalid Authentication

**Problem**: API key works on website but returns 401 in Emacs

**Cause**: Kimi Code China API keys (`sk-kimi-...` from console.kimi.com) are incompatible with standard Moonshot API (`api.moonshot.cn`)

**Solution**: Use the correct provider:

```elisp
;; Wrong - uses api.moonshot.cn
(setq chat-llm-kimi-api-key "sk-kimi-...")
(setq chat-default-model 'kimi)

;; Right - uses api.kimi.com/coding
(setq chat-llm-kimi-code-api-key "sk-kimi-...")
(setq chat-default-model 'kimi-code)
```

### 403 Access Denied (Kimi Code China)

**Problem**: `{"error":{"message":"Kimi For Coding is currently only available for Coding Agents..."}}`

**Cause**: Kimi Code China API requires specific User-Agent from approved coding agents

**Solution**: Set `url-user-agent` variable (NOT headers):

```elisp
;; Wrong - headers don't work for User-Agent in url library
'(("User-Agent" . "claude-code/0.1.0"))

;; Right - use variable binding
(let ((url-user-agent "claude-code/0.1.0"))
  (url-retrieve-synchronously ...))
```

---

## JSON Serialization

### Nested Property Lists

**Problem**: `json-encode` returns malformed JSON for nested plists

**Symptom**: 
```elisp
(json-encode (list :role "user" :content "hello"))
;; => {"role":["user","content","hello"]}  ❌ WRONG
```

**Solution**: Use alist with vconcat:

```elisp
;; Correct - produces valid JSON array
(vconcat '(((role . "user") (content . "hello"))))
;; => [{"role":"user","content":"hello"}]  ✅ CORRECT
```

### JSON Parsing in Tests

**Problem**: Hand-written JSON strings in tests fail to parse correctly

**Solution**: Use elisp data structures with `json-encode`:

```elisp
;; Wrong
"{\"choices\": [{\"delta\": {\"content\": \"text\"}}]}"

;; Right
(json-encode '((choices . [((delta . ((content . "text"))))])))
```

---

## Threading and Async

### Emacs Hangs on API Request

**Problem**: `make-thread` + `url-retrieve-synchronously` + `sit-for` causes deadlock

**Symptom**: Emacs UI freezes indefinitely, "Getting response from AI..." persists

**Root Cause**: Thread-local variables and event loop interference

**Solution**: Use `run-with-idle-timer` instead of `make-thread`:

```elisp
;; Wrong - causes deadlock
(make-thread
 (lambda ()
   (let ((response (chat-llm-request ...)))
     (run-at-time 0 nil #'update-ui response))))

;; Right - non-blocking async
(run-with-idle-timer 0.1 nil
 (lambda ()
   (let ((response (chat-llm-request ...)))
     (run-at-time 0 nil #'update-ui response))))
```

---

## Session Management

### Model Change Not Taking Effect

**Problem**: Changed `chat-default-model` but old session still uses old model

**Symptom**: 
```
[CHAT-LOG] Model: kimi  ; <- expected 'kimi-code
```

**Cause**: Session files persist model information

**Solution**: Create new session after changing default model:

```elisp
;; Changing config doesn't affect existing sessions
(setq chat-default-model 'kimi-code)  ; Old sessions unaffected

;; Must create new session
M-x chat-new-session  ; New session uses 'kimi-code
```

### Hardcoded Default Model

**Problem**: `chat-session-create` used `'gpt-4o` instead of `chat-default-model`

**Solution**: Fixed in chat-session.el to use:
```elisp
:model-id (or model-id (bound-and-true-p chat-default-model) 'kimi)
```

---

## Test Runner

### `tests/run-tests.sh` Cannot Load `chat-tool-caller`

**Problem**: Running `bash tests/run-tests.sh` fails before tests start

**Cause**: The shell runner does not load the full source chain needed by `chat-ui.el`

**Solution**: Use the batch entry at `tests/run-tests.el` as the canonical runner until the shell script is aligned

```bash
emacs -Q -batch -l tests/run-tests.el
```

---

## File I/O

### UTF-8 Encoding Errors

**Problem**: `Cannot safely encode these characters` when writing logs

**Symptom**: Interactive prompt to select coding system

**Solution**: Explicitly set coding system:

```elisp
(let ((coding-system-for-write 'utf-8))
  (write-region ...))
```

---

## Test Loading

**Problem**: Tests fail because source files not loaded

**Solution**: Ensure run-tests.el loads source files before test files

```elisp
(dolist (src '("chat-session"))
  (load (expand-file-name (format "%s.el" src) source-dir) nil t))
```

---

## Streaming JSON Parsing

### `choices` Container Type Drift

**Problem**: Streaming chunk parsing returns nil even though the payload contains content

**Cause**: Some paths decode JSON arrays as lists while provider parsers assume vectors

**Solution**: Provider response parsers and stream parsers should accept both list and vector choices

```elisp
(let ((first-choice (and choices
                         (if (vectorp choices)
                             (aref choices 0)
                           (car choices)))))
  ...)
```

---

## Timestamp Handling

**Problem**: decode-time expects specific format from parse-time-string

**Solution**: Always serialize timestamps as ISO 8601 strings

```elisp
(format-time-string "%Y-%m-%dT%H:%M:%S" (current-time))
```

---

## Parenthesis Counting

**Problem**: Difficult to track matching parentheses in complex nested forms

**Solution**: Use check-parens frequently and write tests to verify code loads correctly

## Load Path in Batch Mode

**Problem**: Relative paths do not work reliably in Emacs batch mode with --eval

**Solution**: Use -l parameter with explicit file paths or shell script wrappers

---

## Tool Calling

### Prompt Parse Execute Drift

**Problem**: Tool calling fails even when the model returns a JSON object

**Cause**: The system prompt response format, response parser, and executor argument mapping drifted apart

**Solution**: Keep one formal contract across all three layers
Use one JSON object with `function_call`
Parse both bare JSON and fenced JSON for compatibility
Map arguments by declared parameter names instead of hardcoded `input`

### Streaming Path Bypasses Tool Calling

**Problem**: Streaming mode displays tool JSON but never executes the tool

**Cause**: `chat-ui--get-response-streaming` appended chunks directly to the buffer and saved the final text without running tool post processing

**Solution**: Finalize streaming responses through the same response processing path used by the sync flow

### SSE Partial Line Loss

**Problem**: Stream chunks randomly lose content or break JSON boundaries

**Cause**: SSE parsing handled each process chunk independently and ignored partial lines

**Solution**: Keep a per process partial line buffer and only parse complete SSE lines

### Empty Source Tools Break Loading

**Problem**: Loading a saved built in tool with no source body raises EOF

**Cause**: The loader treated trailing whitespace as source code and attempted to compile it

**Solution**: Trim loaded tool bodies and convert empty content to nil before compiling

### Built In Tool Gets Overridden By Saved Copy

**Problem**: `shell_execute` shows wrong argument names and fails with `Tool not compiled`

**Cause**: The built in tool was registered before loading saved tools
The registry entry was later overwritten by a saved empty source file with the same id

**Solution**: Load saved tools before registering built in tools
Do not persist tools that only have an in memory compiled function and no source body

### Built In Tool Is Registered But Inactive

**Problem**: `shell_execute` appears in the prompt but execution fails with `Tool is not active`

**Cause**: `chat-forged-tool` defaults to inactive unless `:is-active t` is set explicitly

**Solution**: Mark built in tools active when registering them and add a regression test for the active flag

### Tool Results Are Not Fed Back To The Model

**Problem**: The first shell call works but later turns keep repeating the same command and never answer the real question

**Cause**: Tool execution results were saved only in `toolResults`
The assistant message content stayed empty
Later requests filtered out empty assistant messages so the model never saw the tool output

**Solution**: Add a tool loop that sends tool results back in a follow up system message
Also persist a readable tool summary in assistant content when no natural language answer is produced

### Narrow Shell Whitelist Causes Weak Capability

**Problem**: Simple filesystem questions still fail even when tool calling works

**Cause**: The shell whitelist lacked commands needed for common inspection tasks such as directory size and aggregation

**Solution**: Expand the whitelist to include `du` `stat` `sort` `uniq` `cut` `sed` `awk` and `tr`

---

## Development Checklist

Before starting new features:

- [ ] **HTTP API integration** → Write Python/Elisp prototype first
- [ ] **JSON construction** → Use `vconcat` + alist, never plist
- [ ] **User-Agent** → Use `url-user-agent` variable, never headers
- [ ] **Async processing** → Use `run-with-idle-timer`, never `make-thread`
- [ ] **Session model** → Need `chat-new-session` after config change
- [ ] **Encoding issues** → Set `coding-system-for-write` for file ops

---

## Quick Reference: All Fixes (2026-03-24)

| Issue | Error/Symptom | Fix |
|-------|---------------|-----|
| API Key Mismatch | 401 Invalid Authentication | Use `kimi-code` provider |
| JSON Encoding | Malformed request body | alist + vconcat |
| User-Agent | 403 Access Denied | `url-user-agent` variable |
| Thread Deadlock | Emacs freezes | `run-with-idle-timer` |
| Hardcoded Model | Config ignored | Fix `chat-session-create` |
| UTF-8 Encoding | Coding system prompt | `coding-system-for-write` |
| Old Session | Model not updating | `chat-new-session` |

---

*Last updated: 2026-03-25*
