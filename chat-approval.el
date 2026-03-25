;;; chat-approval.el --- Approval flow for chat.el -*- lexical-binding: t -*-
;; Copyright (C) 2026 chat.el contributors
;; Author: chat.el contributors
;; Keywords: chat, tools, safety
;;; Commentary:
;; This module centralizes approval checks for risky tool calls.
;;; Code:
(require 'cl-lib)
(require 'subr-x)
(defgroup chat-approval nil
  "Approval handling for chat.el."
  :group 'chat)
(defcustom chat-approval-enabled t
  "Whether risky tools require explicit approval."
  :type 'boolean
  :group 'chat-approval)
(defcustom chat-approval-required-tools
  '(files_write files_replace files_patch shell_execute)
  "Tools that require approval before execution."
  :type '(repeat symbol)
  :group 'chat-approval)
(defcustom chat-approval-risk-levels
  '((files_write . medium)
    (files_replace . medium)
    (files_patch . high)
    (shell_execute . high))
  "Risk level mapping for tool approvals."
  :type '(alist :key-type symbol :value-type symbol)
  :group 'chat-approval)
(defcustom chat-approval-max-summary-length 160
  "Maximum length for argument summaries in approval prompts."
  :type 'integer
  :group 'chat-approval)
(defcustom chat-approval-noninteractive-policy 'deny
  "Policy for approvals in noninteractive sessions."
  :type '(choice (const :tag "Approve" approve)
                 (const :tag "Deny" deny)
                 (const :tag "Ask" ask))
  :group 'chat-approval)
(defun chat-approval-tool-required-p (tool-id)
  "Return non-nil when TOOL-ID requires approval."
  (memq tool-id chat-approval-required-tools))
(defun chat-approval--summarize-value (value)
  "Return a short string summary for VALUE."
  (let ((printed (if (stringp value)
                     value
                   (prin1-to-string value))))
    (truncate-string-to-width printed chat-approval-max-summary-length nil nil t)))
(defun chat-approval--summarize-arguments (arguments)
  "Return a readable summary string for ARGUMENTS."
  (if (null arguments)
      "no arguments"
    (mapconcat
     (lambda (entry)
       (format "%s=%s"
               (car entry)
               (chat-approval--summarize-value (cdr entry))))
     arguments
     ", ")))
(defun chat-approval--risk-level (tool-id)
  "Return the configured risk level for TOOL-ID."
  (or (alist-get tool-id chat-approval-risk-levels)
      'medium))
(defun chat-approval--prompt (tool-id arguments)
  "Build an approval prompt for TOOL-ID with ARGUMENTS."
  (format "Approve %s risk tool %s with %s? "
          (chat-approval--risk-level tool-id)
          tool-id
          (chat-approval--summarize-arguments arguments)))
(defun chat-approval-request-tool-call (tool call)
  "Request approval for TOOL using CALL data.
Returns non-nil when execution should proceed."
  (let* ((tool-id (chat-forged-tool-id tool))
         (arguments (plist-get call :arguments))
         (prompt (chat-approval--prompt tool-id arguments)))
    (cond
     ((not chat-approval-enabled) t)
     ((not (chat-approval-tool-required-p tool-id)) t)
     ((and noninteractive
           (eq chat-approval-noninteractive-policy 'approve))
      t)
     ((and noninteractive
           (eq chat-approval-noninteractive-policy 'deny))
      nil)
     (t
      (y-or-n-p prompt)))))
(provide 'chat-approval)
;;; chat-approval.el ends here
