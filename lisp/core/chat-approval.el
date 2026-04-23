;;; chat-approval.el --- Approval flow for chat.el -*- lexical-binding: t -*-
;; Copyright (C) 2026 chat.el contributors
;; Author: chat.el contributors
;; Keywords: chat, tools, safety
;;; Commentary:
;; This module centralizes approval checks for risky tool calls.
;;; Code:
(require 'cl-lib)
(require 'subr-x)

;; Forward declarations
(declare-function chat-forged-tool-id "chat-tool-forge" (tool))
(declare-function chat-session-auto-approve-p "chat-session" (session))
(declare-function chat-session-set-auto-approve "chat-session" (session value))
(defgroup chat-approval nil
  "Approval handling for chat.el."
  :group 'chat)
(defcustom chat-approval-enabled t
  "Whether risky tools require explicit approval."
  :type 'boolean
  :group 'chat-approval)
(defcustom chat-approval-required-tools
  '(files_write files_replace files_patch apply_patch shell_execute)
  "Tools that require approval before execution."
  :type '(repeat symbol)
  :group 'chat-approval)
(defcustom chat-approval-risk-levels
  '((files_write . medium)
    (files_replace . medium)
    (files_patch . high)
    (apply_patch . high)
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
(defcustom chat-approval-tool-creation-required t
  "Whether AI generated tools require explicit approval."
  :type 'boolean
  :group 'chat-approval)

(defcustom chat-approval-auto-approve-global nil
  "Whether to auto-approve tools without prompting.
When non-nil, tools in `chat-approval-auto-approve-tools' will be
executed without user confirmation."
  :type 'boolean
  :group 'chat-approval)

(defcustom chat-approval-auto-approve-tools
  '(files_read files_grep apply_patch)
  "Tools that can be auto-approved when `chat-approval-auto-approve-global' is t.
Note: shell_execute is excluded by default for security."
  :type '(repeat symbol)
  :group 'chat-approval)

(defcustom chat-approval-always-approve-tools nil
  "Tools that are always approved without prompting."
  :type '(repeat symbol)
  :group 'chat-approval)

(defcustom chat-approval-decision-function nil
  "Optional function that returns an approval decision symbol."
  :type '(choice (const :tag "Default prompt" nil)
                 function)
  :group 'chat-approval)

(defvar chat-approval--pending-request nil
  "Current pending approval request.")

(defvar chat-approval--pending-decision nil
  "Current approval decision selected through a command shortcut.")

(defun chat-approval-tool-required-p (tool-id)
  "Return non-nil when TOOL-ID requires approval."
  (memq tool-id chat-approval-required-tools))

(defun chat-approval-shortcut-summary (tool-id)
  "Return a human-readable shortcut summary for TOOL-ID."
  (mapconcat #'identity
             (chat-approval--action-hints tool-id)
             ", "))

(defun chat-approval-pending-message (tool actions)
  "Return a native approval hint message for TOOL and ACTIONS."
  (format "Approval pending for %s. Use %s."
          tool
          (mapconcat #'identity actions ", ")))

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
  (format "Approve %s risk tool %s with %s? Shortcuts: %s. "
          (chat-approval--risk-level tool-id)
          tool-id
          (chat-approval--summarize-arguments arguments)
          (chat-approval-shortcut-summary tool-id)))

(defun chat-approval--allow-noninteractive-p ()
  "Return non nil when the current noninteractive policy allows execution."
  (and noninteractive
       (eq chat-approval-noninteractive-policy 'approve)))

(defun chat-approval--deny-noninteractive-p ()
  "Return non nil when the current noninteractive policy denies execution."
  (and noninteractive
       (eq chat-approval-noninteractive-policy 'deny)))

(defun chat-approval--auto-approve-p (tool-id &optional session)
  "Return non-nil when TOOL-ID should be auto-approved.
Check global settings and SESSION-specific settings."
  (let ((session-auto-approve
         (when session
           (and (fboundp 'chat-session-auto-approve-p)
                (chat-session-auto-approve-p session))))
        (global-auto-approve chat-approval-auto-approve-global)
        (in-auto-approve-list (memq tool-id chat-approval-auto-approve-tools))
        (always-auto-approve (memq tool-id chat-approval-always-approve-tools)))
    (and (or session-auto-approve
             always-auto-approve
             (and global-auto-approve in-auto-approve-list))
         t)))

(defun chat-approval--notify (observer event)
  "Send EVENT to OBSERVER."
  (when observer
    (funcall observer event)))

(defun chat-approval--command-from-arguments (arguments)
  "Return shell command string from ARGUMENTS when present."
  (cdr (assoc "command" arguments)))

(defun chat-approval--decision-options (tool-id)
  "Return available decisions for TOOL-ID."
  (append
   '(("allow once" . allow-once)
     ("allow for session" . allow-session)
     ("always allow this tool" . allow-tool))
   (when (eq tool-id 'shell_execute)
     '(("always allow this command" . allow-command)))
   '(("deny" . deny))))

(defun chat-approval--action-hints (tool-id)
  "Return display strings for TOOL-ID approval shortcuts."
  (append
   '("C-c C-a once"
     "C-c C-s session"
     "C-c C-t tool")
   (when (eq tool-id 'shell_execute)
     '("C-c C-c command"))
   '("C-c C-d deny")))

(defun chat-approval--event-context (tool-id arguments)
  "Return shared event context for TOOL-ID and ARGUMENTS."
  (let ((command (chat-approval--command-from-arguments arguments)))
    (append
     (list :risk (chat-approval--risk-level tool-id))
     (list :actions (chat-approval--action-hints tool-id))
     (when command
       (list :command command)))))

(defun chat-approval--set-pending-decision (decision)
  "Set pending approval DECISION and exit the minibuffer when active."
  (unless chat-approval--pending-request
    (user-error "No pending approval"))
  (setq chat-approval--pending-decision decision)
  (when (active-minibuffer-window)
    (exit-minibuffer)))

(defun chat-approval-allow-once ()
  "Approve the current pending request once."
  (interactive)
  (chat-approval--set-pending-decision 'allow-once))

(defun chat-approval-allow-session ()
  "Approve the current pending request for this session."
  (interactive)
  (chat-approval--set-pending-decision 'allow-session))

(defun chat-approval-allow-tool ()
  "Always approve the current pending tool."
  (interactive)
  (chat-approval--set-pending-decision 'allow-tool))

(defun chat-approval-allow-command ()
  "Always approve the current pending shell command."
  (interactive)
  (chat-approval--set-pending-decision 'allow-command))

(defun chat-approval-deny ()
  "Deny the current pending approval request."
  (interactive)
  (chat-approval--set-pending-decision 'deny))

(defun chat-approval--install-minibuffer-bindings ()
  "Install approval shortcut bindings in the active minibuffer."
  (use-local-map (copy-keymap (current-local-map)))
  (local-set-key (kbd "C-c C-a") #'chat-approval-allow-once)
  (local-set-key (kbd "C-c C-s") #'chat-approval-allow-session)
  (local-set-key (kbd "C-c C-t") #'chat-approval-allow-tool)
  (local-set-key (kbd "C-c C-c") #'chat-approval-allow-command)
  (local-set-key (kbd "C-c C-d") #'chat-approval-deny))

(defun chat-approval--prompt-for-decision (tool-id arguments)
  "Prompt for TOOL-ID with ARGUMENTS and return a decision symbol."
  (let* ((choices (chat-approval--decision-options tool-id))
         (chat-approval--pending-request
          (list :tool-id tool-id
                :arguments arguments
                :options choices))
         (chat-approval--pending-decision nil)
         choice)
    (unwind-protect
        (progn
          (setq choice
                (minibuffer-with-setup-hook
                    #'chat-approval--install-minibuffer-bindings
                  (completing-read
                   (chat-approval--prompt tool-id arguments)
                   (mapcar #'car choices)
                   nil
                   t
                   nil
                   nil
                   "allow once")))
          (or chat-approval--pending-decision
              (cdr (assoc choice choices))
              'deny))
      (setq chat-approval--pending-request nil)
      (setq chat-approval--pending-decision nil))))

(defun chat-approval--decide (tool-id arguments &optional session)
  "Return approval decision for TOOL-ID with ARGUMENTS and SESSION."
  (cond
   (chat-approval-decision-function
    (funcall chat-approval-decision-function tool-id arguments session))
   (t
    (chat-approval--prompt-for-decision tool-id arguments))))

(defun chat-approval--apply-decision (tool-id arguments decision &optional session)
  "Apply DECISION for TOOL-ID with ARGUMENTS and SESSION."
  (pcase decision
    ('allow-once t)
    ('allow-session
     (when (and session
                (fboundp 'chat-session-set-auto-approve))
       (chat-session-set-auto-approve session t))
     t)
    ('allow-tool
     (unless (memq tool-id chat-approval-always-approve-tools)
       (push tool-id chat-approval-always-approve-tools))
     t)
    ('allow-command
     (let ((command (cdr (assoc "command" arguments))))
       (when (and command
                  (require 'chat-tool-shell nil t)
                  (fboundp 'chat-tool-shell-whitelist-add))
         (chat-tool-shell-whitelist-add command))
       (and command t)))
    ('deny nil)
    (_ nil)))

(defun chat-approval-request-tool-call (tool call &optional session observer)
  "Request approval for TOOL using CALL data.
Optional SESSION is the current chat session for context.
Returns non-nil when execution should proceed."
  (let* ((tool-id (chat-forged-tool-id tool))
         (arguments (plist-get call :arguments))
         (prompt (chat-approval--prompt tool-id arguments)))
    (cond
     ((not chat-approval-enabled) t)
     ((not (chat-approval-tool-required-p tool-id)) t)
     ((chat-approval--auto-approve-p tool-id session)
      (chat-approval--notify
       observer
       (append
        (list :type 'approval
              :tool (symbol-name tool-id)
              :decision 'auto
              :approved t)
        (chat-approval--event-context tool-id arguments)))
      t)
     ((chat-approval--allow-noninteractive-p)
      t)
     ((chat-approval--deny-noninteractive-p)
      nil)
     (t
     (chat-approval--notify
       observer
       (append
        (list :type 'approval-pending
              :tool (symbol-name tool-id)
              :prompt prompt
              :options (chat-approval--decision-options tool-id))
        (chat-approval--event-context tool-id arguments)))
      (let* ((decision (chat-approval--decide tool-id arguments session))
             (approved (chat-approval--apply-decision
                        tool-id arguments decision session)))
        (when (eq decision 'allow-command)
          (when-let ((command (chat-approval--command-from-arguments arguments)))
            (chat-approval--notify
             observer
             (list :type 'whitelist-update
                   :tool (symbol-name tool-id)
                   :scope 'command
                   :pattern command
                   :approved t))))
        (chat-approval--notify
         observer
         (append
          (list :type 'approval
                :tool (symbol-name tool-id)
                :decision decision
                :approved approved)
          (chat-approval--event-context tool-id arguments)))
        approved)))))

(defun chat-approval-request-tool-creation (description spec)
  "Request approval for creating a generated tool from DESCRIPTION and SPEC."
  (let* ((tool-id (plist-get spec :id))
         (language (plist-get spec :language))
         (prompt (format
                  "Approve high risk tool creation %s in %s for %s? "
                  tool-id
                  language
                  (chat-approval--summarize-value description))))
    (cond
     ((not chat-approval-enabled) t)
     ((not chat-approval-tool-creation-required) t)
     ((chat-approval--allow-noninteractive-p) t)
     ((chat-approval--deny-noninteractive-p) nil)
     (t
      (y-or-n-p prompt)))))
(provide 'chat-approval)
;;; chat-approval.el ends here
