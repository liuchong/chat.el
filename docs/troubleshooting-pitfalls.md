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

*Last updated: 2026-03-24*
