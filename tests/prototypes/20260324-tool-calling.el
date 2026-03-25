#!/usr/bin/env emacs -Q --script
;;; Tool Calling Prototype -*- lexical-binding: t -*-

;; Test tool calling protocol design

;; Simulate available tools
(defvar proto-tools
  '((word-counter . 
     (:name "word-counter"
      :description "Count words in text"
      :parameters ((text . "string"))))
    (line-counter .
     (:name "line-counter"
      :description "Count lines in text"
      :parameters ((text . "string"))))))

;; Tool calling protocol prompt
(defun proto-build-tool-prompt (user-input tools)
  "Build prompt that enables tool calling."
  (let ((tool-descriptions
         (mapconcat 
          (lambda (tool)
            (let ((spec (cdr tool)))
              (format "- %s: %s\n  Parameters: %s"
                      (plist-get spec :name)
                      (plist-get spec :description)
                      (plist-get spec :parameters))))
          tools
          "\n")))
    (format "You are a helpful assistant with access to tools.

Available tools:
%s

When you need to use a tool, respond with JSON in this format:
{\"tool_call\": {\"name\": \"tool-name\", \"arguments\": {\"param\": \"value\"}}}

After receiving tool results, respond naturally to the user.

User: %s"
            tool-descriptions
            user-input)))

;; Test the prompt building
(let ((prompt (proto-build-tool-prompt 
               "Count words in 'hello world foo bar'"
               proto-tools)))
  (message "=== Generated Prompt ===")
  (message "%s" prompt)
  (message "\n=== Test Complete ==="))

;; Simulate parsing tool call from AI response
(defun proto-parse-tool-call (response)
  "Parse tool call from AI response."
  (condition-case err
      (when (string-match "{\\s*\"tool_call\"\\s*:.*}" response)
        (let* ((json-str (match-string 0 response))
               (json-object-type 'plist)
               (data (json-read-from-string json-str)))
          (plist-get data :tool_call)))
    (error nil)))

;; Test parsing
(let ((test-responses
       '("I'll count those words for you.\n{\"tool_call\": {\"name\": \"word-counter\", \"arguments\": {\"text\": \"hello world foo bar\"}}}"
         "Let me analyze this.\n{\"tool_call\":{\"name\":\"line-counter\",\"arguments\":{\"text\":\"line1\\nline2\"}}}",
         "Just a plain response without tool call")))
  (message "\n=== Tool Call Parsing Tests ===")
  (dolist (resp test-responses)
    (message "\nInput: %s" (substring resp 0 (min 50 (length resp))))
    (let ((parsed (proto-parse-tool-call resp)))
      (if parsed
          (message "Parsed: name=%s, args=%S" 
                   (plist-get parsed :name)
                   (plist-get parsed :arguments))
        (message "Parsed: no tool call")))))

(kill-emacs 0)
