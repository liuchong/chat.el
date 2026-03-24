;;; chat-tool-caller.el --- AI tool calling for chat.el -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: tools, ai, function-calling

;;; Commentary:

;; This module enables AI to call tools during conversation.
;; It handles tool discovery, call parsing, execution, and result integration.

;;; Code:

(require 'chat-tool-forge)
(require 'json)

;; ------------------------------------------------------------------
;; Configuration
;; ------------------------------------------------------------------

(defcustom chat-tool-caller-enabled t
  "Enable AI tool calling."
  :type 'boolean
  :group 'chat)

(defcustom chat-tool-caller-max-iterations 5
  "Maximum number of tool calls per user message."
  :type 'integer
  :group 'chat)

;; ------------------------------------------------------------------
;; Tool Discovery
;; ------------------------------------------------------------------

(defun chat-tool-caller--available-tools ()
  "Get list of available tools in OpenAI function format."
  (let ((tools (chat-tool-forge-list)))
    (mapcar (lambda (tool)
              `((type . "function")
                (function . ((name . ,(symbol-name (chat-forged-tool-id tool)))
                            (description . ,(chat-forged-tool-description tool))
                            (parameters . ((type . "object")
                                          (properties . ,(chat-tool-caller--extract-params tool))
                                          (required . ,(chat-tool-caller--required-params tool))))))))
            tools)))

(defun chat-tool-caller--extract-params (tool)
  "Extract parameter schema from TOOL."
  ;; For now, assume single "input" parameter
  ;; TODO: Extract actual parameters from tool lambda
  '((input . ((type . "string")
              (description . "Input text for the tool")))))

(defun chat-tool-caller--required-params (tool)
  "Get required parameters for TOOL."
  '("input"))

;; ------------------------------------------------------------------
;; System Prompt Enhancement
;; ------------------------------------------------------------------

(defun chat-tool-caller-build-system-prompt (base-prompt)
  "Add tool calling instructions to BASE-PROMPT."
  (if (not chat-tool-caller-enabled)
      base-prompt
    (let ((tools (chat-tool-caller--available-tools)))
      (if (null tools)
          base-prompt
        (format "%s\n\nYou have access to the following tools. When you need to use a tool, respond with a function_call in this exact format:\n\n<function_calls>\n<invoke name=\"TOOL_NAME\">\n<parameter name=\"PARAM_NAME\">PARAM_VALUE</parameter>\n</invoke>\n</function_calls>\n\nAvailable tools:\n%s\n\nAfter receiving tool results, continue helping the user naturally."
                base-prompt
                (chat-tool-caller--format-tools-for-prompt tools))))))

(defun chat-tool-caller--format-tools-for-prompt (tools)
  "Format TOOLS for system prompt."
  (mapconcat (lambda (tool)
               (let* ((func (cdr (assoc 'function tool)))
                      (name (cdr (assoc 'name func)))
                      (desc (cdr (assoc 'description func))))
                 (format "- %s: %s" name desc)))
             tools
             "\n"))

;; ------------------------------------------------------------------
;; Tool Call Parsing
;; ------------------------------------------------------------------

(defun chat-tool-caller-parse (content)
  "Parse tool calls from AI response CONTENT.

Returns a list of tool call plists with :name and :arguments,
or nil if no tool calls found."
  (when (string-match-p "<function_calls>" content)
    (let ((calls nil)
          (pos 0))
      (while (string-match "<invoke name=\"\\([^\"]+\\)\"[^>]*>" content pos)
        (let ((name (match-string 1 content))
              (start (match-end 0))
              (end (string-match "</invoke>" content (match-end 0))))
          (when end
            (let* ((invoke-content (substring content start end))
                   (args (chat-tool-caller--parse-parameters invoke-content)))
              (push (list :name name :arguments args) calls))
            (setq pos end))))
      (nreverse calls))))

(defun chat-tool-caller--parse-parameters (content)
  "Parse parameters from invoke CONTENT."
  (let ((params nil)
        (pos 0))
    (while (string-match "<parameter name=\"\\([^\"]+\\)\">\\([^<]*\\)</parameter>"
                         content pos)
      (let ((name (match-string 1 content))
            (value (match-string 2 content)))
        (push (cons name value) params)
        (setq pos (match-end 0))))
    params))

;; ------------------------------------------------------------------
;; Tool Execution
;; ------------------------------------------------------------------

(defun chat-tool-caller-execute (tool-call)
  "Execute a single TOOL-CALL and return result.

TOOL-CALL is a plist with :name and :arguments."
  (let* ((name (plist-get tool-call :name))
         (args (plist-get tool-call :arguments))
         (tool-id (intern name))
         (tool (chat-tool-forge-get tool-id)))
    (if (not tool)
        (format "Error: Tool '%s' not found" name)
      (condition-case err
          (let* ((input (cdr (assoc "input" args)))
                 (result (chat-tool-forge-execute tool-id (or input ""))))
            (format "Tool '%s' result: %s" name result))
        (error
         (format "Error executing tool '%s': %s" name (error-message-string err)))))))

(defun chat-tool-caller-execute-all (tool-calls)
  "Execute all TOOL-CALLS and return combined results."
  (mapconcat #'chat-tool-caller-execute tool-calls "\n\n"))

;; ------------------------------------------------------------------
;; Response Processing
;; ------------------------------------------------------------------

(defun chat-tool-caller-extract-content (content)
  "Extract user-facing content, removing tool call markup."
  (with-temp-buffer
    (insert content)
    (goto-char (point-min))
    (while (search-forward "<function_calls>" nil t)
      (let ((start (match-beginning 0)))
        (when (search-forward "</function_calls>" nil t)
          (delete-region start (point))
          (when (looking-at "\\s-*")
            (delete-region (match-beginning 0) (match-end 0))))))
    (buffer-string)))

;; ------------------------------------------------------------------
;; Main Entry Point
;; ------------------------------------------------------------------

(defun chat-tool-caller-process-response (content callback)
  "Process AI response CONTENT, execute any tool calls.

CALLBACK is called with (content tool-results) when done.
CONTENT is the user-facing text (tool calls removed).
TOOL-RESULTS is the combined result string or nil."
  (let* ((tool-calls (chat-tool-caller-parse content))
         (user-content (chat-tool-caller-extract-content content)))
    (if (null tool-calls)
        (funcall callback user-content nil)
      (let ((results (chat-tool-caller-execute-all tool-calls)))
        (funcall callback user-content results)))))

(provide 'chat-tool-caller)
;;; chat-tool-caller.el ends here
