;;; chat-tool-forge-ai.el --- AI-assisted tool generation -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: tools, ai, generation

;; This file is not part of GNU Emacs.

;;; Commentary:

;; This module integrates tool forging with AI conversation.
;; It detects tool creation requests, generates code via LLM,
;; and automatically registers new tools.

;;; Code:

(require 'chat-approval)
(require 'chat-tool-forge)
(require 'chat-llm)

;; ------------------------------------------------------------------
;; Detection
;; ------------------------------------------------------------------

(defcustom chat-tool-forge-ai-trigger-patterns
  '("create a tool" "make a tool" "write a tool" "forge a tool"
    "帮我写个工具" "创建一个工具" "生成一个工具")
  "Patterns that trigger tool generation."
  :type '(repeat string)
  :group 'chat-tool-forge)

(defun chat-tool-forge-ai--tool-request-p (message)
  "Check if MESSAGE is a request to create a tool."
  (let ((case-fold-search t))
    (seq-find (lambda (pattern)
                (string-match-p pattern message))
              chat-tool-forge-ai-trigger-patterns)))

(defun chat-tool-forge-ai--extract-description (message)
  "Extract tool description from MESSAGE."
  ;; Simple extraction - remove trigger words
  (let ((desc (replace-regexp-in-string
               (regexp-opt chat-tool-forge-ai-trigger-patterns 'words)
               ""
               message
               'fixed-case)))
    (string-trim desc)))

;; ------------------------------------------------------------------
;; Prompt Engineering
;; ------------------------------------------------------------------

(defun chat-tool-forge-ai--build-prompt (description)
  "Build LLM prompt for tool generation from DESCRIPTION."
  (let* ((existing-tools (chat-tool-forge-list))
         (tool-list (if existing-tools
                       (mapconcat (lambda (tool)
                                   (format "- %s: %s"
                                          (chat-forged-tool-id tool)
                                          (chat-forged-tool-description tool)))
                                 existing-tools
                                 "\n")
                     "None yet")))
    (format "You are a tool smith for an Emacs-based AI system.

Your task: Create an Emacs Lisp tool based on the description.

Available tools for reference:
%s

Requirements:
1. Create a lambda function that takes appropriate parameters
2. Return the result (don't print)
3. Include docstring explaining what it does
4. Keep it simple and focused on one task
5. Use only standard Emacs Lisp functions

Tool description: %s

Respond with ONLY the Emacs Lisp code, no explanations, no markdown formatting.
The code should be a single lambda expression like:
(lambda (arg1 arg2) \"Docstring\" (do-something arg1 arg2))"
           tool-list
           description)))

;; ------------------------------------------------------------------
;; Tool Generation
;; ------------------------------------------------------------------

(defun chat-tool-forge-ai-generate (description &optional model)
  "Generate tool from DESCRIPTION using MODEL (defaults to chat-default-model)."
  (let* ((prompt (chat-tool-forge-ai--build-prompt description))
         (messages (list (make-chat-message
                         :id "system"
                         :role :system
                         :content "You are a tool smith.")))
         (_ (push (make-chat-message
                  :id "user"
                  :role :user
                  :content prompt)
                 messages))
         (model (or model chat-default-model))
         ;; Get AI response
         (response (chat-llm-request model messages
                                    '(:temperature 0.2 :max-tokens 500)))
         ;; Parse response into tool spec
         (spec (chat-tool-forge-ai--parse-response response description)))
    spec))

(defun chat-tool-forge-ai--parse-response (response description)
  "Parse LLM RESPONSE into tool spec plist."
  (let* ((content (if (stringp response)
                      response
                    (plist-get response :content)))
         (code (chat-tool-forge-ai--extract-code content))
         (id (chat-tool-forge-ai--generate-id description))
         (name (chat-tool-forge-ai--generate-name description)))
    (list :id id
          :name name
          :description description
          :language 'elisp
          :source-code code
          :version "1.0.0"
          :created-at (current-time)
          :updated-at (current-time)
          :usage-count 0
          :is-active t)))

(defun chat-tool-forge-ai--extract-code (response)
  "Extract code from LLM RESPONSE."
  ;; Remove markdown code blocks if present
  (let ((code (replace-regexp-in-string "```[^\n]*\n" "" (or response ""))))
    (setq code (replace-regexp-in-string "```" "" code))
    (string-trim code)))

(defun chat-tool-forge-ai--generate-id (description)
  "Generate tool ID from DESCRIPTION."
  (let* ((words (split-string (downcase description)))
         (key-words (seq-take (seq-remove (lambda (w)
                                           (member w '("a" "an" "the" "that" "which"
                                                      "create" "make" "write" "tool"
                                                      "帮我" "创建" "一个" "工具")))
                                         words)
                             3))
         (id-str (mapconcat #'identity key-words "-")))
    (intern (if (string= id-str "")
               "custom-tool"
              id-str))))

(defun chat-tool-forge-ai--generate-name (description)
  "Generate human-readable tool name from DESCRIPTION."
  (let ((name (replace-regexp-in-string "\\(create\\|make\\|write\\) a\\(n\\)? tool\\(to\\|that\\)?"
                                       ""
                                       description
                                       'fixed-case)))
    (string-trim (capitalize name))))

;; ------------------------------------------------------------------
;; Integration
;; ------------------------------------------------------------------

(defun chat-tool-forge-ai-create-and-register (description &optional model)
  "Create tool from DESCRIPTION and register it.
Returns the created tool or nil on failure."
  (condition-case err
      (let* ((spec (chat-tool-forge-ai-generate description model))
             (tool (and (chat-approval-request-tool-creation description spec)
                        (apply #'make-chat-forged-tool spec))))
        (when tool
          ;; Validate the code compiles
          (when (eq (chat-forged-tool-language tool) 'elisp)
            (chat-tool-forge--compile-elisp tool))
          ;; Register
          (chat-tool-forge-register tool)
          tool))
    (error
     (message "Tool generation failed: %s" (error-message-string err))
     nil)))

(defun chat-tool-forge-ai-handle-message (message)
  "Check if MESSAGE requests tool creation and handle it.
Returns created tool if handled, nil otherwise."
  (when (chat-tool-forge-ai--tool-request-p message)
    (let ((description (chat-tool-forge-ai--extract-description message)))
      (when (> (length description) 5)  ;; Minimum description length
        (chat-tool-forge-ai-create-and-register description)))))

(provide 'chat-tool-forge-ai)
;;; chat-tool-forge-ai.el ends here
