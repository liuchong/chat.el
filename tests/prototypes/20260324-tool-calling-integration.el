#!/usr/bin/env emacs -Q --script
;;; Tool Calling Integration Test -*- lexical-binding: t -*-

(load (expand-file-name "../test-paths.el" (file-name-directory load-file-name)) nil t)

(require 'chat-tool-forge)
(require 'chat-tool-caller)

;; Create a test tool
(let ((tool (make-chat-forged-tool
             :id 'word-counter
             :name "Word Counter"
             :description "Count words in text"
             :language 'elisp
             :source-code "(lambda (text) (length (split-string text)))"
             :compiled-function (lambda (text) (length (split-string text)))
             :is-active t)))
  (chat-tool-forge-register tool))

(message "=== Tool Calling Integration Test ===")
(message "Available tools: %S" (mapcar #'chat-forged-tool-id (chat-tool-forge-list)))

;; Test 1: Build system prompt
(message "\n--- Test 1: System Prompt ---")
(let ((prompt (chat-tool-caller-build-system-prompt "You are helpful.")))
  (message "Generated prompt length: %d" (length prompt))
  (message "Contains tool info: %s" (if (string-match-p "word-counter" prompt) "YES" "NO")))

;; Test 2: Parse tool call
(message "\n--- Test 2: Parse Tool Call ---")
(let ((response "I'll count the words for you.
<function_calls>
<invoke name=\"word-counter\">
<parameter name=\"input\">hello world foo bar</parameter>
</invoke>
</function_calls>"))
  (let ((calls (chat-tool-caller-parse response)))
    (message "Found %d tool call(s)" (length calls))
    (when calls
      (message "Tool name: %s" (plist-get (car calls) :name))
      (message "Arguments: %S" (plist-get (car calls) :arguments)))))

;; Test 3: Extract content
(message "\n--- Test 3: Extract Content ---")
(let ((response "Here is the result:
<function_calls>
<invoke name=\"word-counter\">
<parameter name=\"input\">test</parameter>
</invoke>
</function_calls>"))
  (message "Original length: %d" (length response))
  (message "Extracted: %S" (chat-tool-caller-extract-content response)))

;; Test 4: Execute tool
(message "\n--- Test 4: Execute Tool ---")
(let ((tool-call '(:name "word-counter" :arguments (("input" . "hello world test")))))
  (message "Executing: %S" tool-call)
  (message "Result: %s" (chat-tool-caller-execute tool-call)))

;; Test 5: Process response
(message "\n--- Test 5: Process Response ---")
(let ((response "Let me count.
<function_calls>
<invoke name=\"word-counter\">
<parameter name=\"input\">one two three</parameter>
</invoke>
</function_calls>"))
  (chat-tool-caller-process-response
   response
   (lambda (content tool-results)
     (message "User content: %S" content)
     (message "Tool results: %S" tool-results))))

(message "\n=== Integration Test Complete ===")
(kill-emacs 0)
