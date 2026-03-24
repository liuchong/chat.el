# Troubleshooting and Pitfalls

This document records known issues and their solutions for chat.el development.

## JSON Serialization

**Problem**: json-read-from-string returns alist not plist

**Symptom**: Deserialization fails with nil values or parse errors

**Solution**: Use alist format consistently for JSON serialization

```elisp
;; Wrong - plist
(list :id value :name value)

;; Right - alist
`((id . ,value) (name . ,value))

;; Access with
(cdr (assoc 'key alist))
```

## Test Loading

**Problem**: Tests fail because source files not loaded

**Solution**: Ensure run-tests.el loads source files before test files

```elisp
(dolist (src '("chat-session"))
  (load (expand-file-name (format "%s.el" src) source-dir) nil t))
```

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

## JSON Data Construction in Tests

**Problem**: Hand-written JSON strings in tests fail to parse correctly

**Solution**: Use elisp data structures with `json-encode` instead of string literals:
```elisp
;; Wrong
"{\"choices\": [{\"delta\": {\"content\": \"text\"}}]}"

;; Right
(json-encode '((choices . [((delta . ((content . "text"))))])))
```

---

*Last updated: 2026-03-24*
