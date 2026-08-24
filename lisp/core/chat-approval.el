;;; chat-approval.el --- Approval flow for chat.el -*- lexical-binding: t -*-
;; Copyright (C) 2026 chat.el contributors
;; Author: chat.el contributors
;; Keywords: chat, tools, safety
;;; Commentary:
;; This module centralizes approval checks for risky tool calls.
;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)

;; Forward declarations
(declare-function chat-forged-tool-id "chat-tool-forge" (tool))
(declare-function chat-forged-tool-p "chat-tool-forge" (tool))
(declare-function chat-forged-tool-sensitivity "chat-tool-forge" (tool))
(declare-function chat-forged-tool-effects "chat-tool-forge" (tool))
(declare-function chat-forged-tool-approval-predicate "chat-tool-forge" (tool))
(declare-function chat-session-auto-approve-p "chat-session" (session))
(declare-function chat-session-set-auto-approve "chat-session" (session value))
(declare-function chat-files--resolved-path "chat-files" (path))
(declare-function chat-files--tool-target-paths "chat-files" (tool-id arguments))
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
(defcustom chat-approval-required-sensitivities
  '(personal correspondence credential network)
  "Data sensitivity classes that require explicit approval."
  :type '(repeat symbol)
  :group 'chat-approval)
(defcustom chat-approval-required-effects
  '(write outbound destructive)
  "Tool effects that require explicit approval."
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

(defcustom chat-approval-always-approve-directories nil
  "Directories whose file-write tool calls are always approved.
Only file writing tools with a clear directory scope can use this whitelist."
  :type '(repeat directory)
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

(defun chat-approval--write-file-tool-p (tool-id)
  "Return non-nil when TOOL-ID is a file-writing tool."
  (memq tool-id '(files_write files_replace files_patch apply_patch)))

(defun chat-approval--normalize-directory (dir)
  "Return canonical directory path for DIR."
  (file-name-as-directory
   (if (fboundp 'chat-files--resolved-path)
       (chat-files--resolved-path dir)
     (expand-file-name dir))))

(defun chat-approval--directory-prefix-p (root dir)
  "Return non-nil when ROOT contains DIR."
  (let ((normalized-root (chat-approval--normalize-directory root))
        (normalized-dir (chat-approval--normalize-directory dir)))
    (string-prefix-p normalized-root normalized-dir)))

(defun chat-approval--directory-parent (dir)
  "Return the parent directory for DIR, or nil at filesystem root."
  (let* ((trimmed (directory-file-name (chat-approval--normalize-directory dir)))
         (parent (file-name-directory trimmed)))
    (when (and parent
               (not (string= trimmed "/"))
               (not (string= (chat-approval--normalize-directory parent)
                             (chat-approval--normalize-directory dir))))
      parent)))

(defun chat-approval--common-directory (dirs)
  "Return the narrowest shared ancestor directory for DIRS."
  (when dirs
    (let ((common (chat-approval--normalize-directory (car dirs))))
      (dolist (dir (cdr dirs))
        (let ((candidate (chat-approval--normalize-directory dir)))
          (while (and common
                      (not (chat-approval--directory-prefix-p common candidate)))
            (setq common (chat-approval--directory-parent common)))))
      (unless (or (null common)
                  (string= common "/"))
        common))))

(defun chat-approval--tool-target-directories (tool-id arguments)
  "Return canonical target directories for TOOL-ID and ARGUMENTS."
  (condition-case nil
      (when-let ((paths (chat-files--tool-target-paths tool-id arguments)))
        (delete-dups
         (mapcar #'file-name-directory paths)))
    (error nil)))

(defun chat-approval--directory-scope (tool-id arguments)
  "Return the directory scope for TOOL-ID and ARGUMENTS, or nil."
  (when (chat-approval--write-file-tool-p tool-id)
    (chat-approval--common-directory
     (chat-approval--tool-target-directories tool-id arguments))))

(defun chat-approval--whitelisted-directory-match (tool-id arguments)
  "Return a matching whitelisted directory for TOOL-ID and ARGUMENTS, or nil."
  (let ((directories (chat-approval--tool-target-directories tool-id arguments)))
    (when directories
      (seq-find
       (lambda (root)
         (let ((normalized-root (chat-approval--normalize-directory root)))
           (seq-every-p
            (lambda (dir)
              (chat-approval--directory-prefix-p normalized-root dir))
            directories)))
       chat-approval-always-approve-directories))))

(defun chat-approval-tool-required-p (tool-or-id &optional call)
  "Return non-nil when TOOL-OR-ID requires approval for CALL.
Forged tools are governed by their sensitivity, effects, and optional
dynamic approval predicate in addition to the legacy tool id list."
  (let* ((tool (and (chat-forged-tool-p tool-or-id) tool-or-id))
         (tool-id (if tool (chat-forged-tool-id tool) tool-or-id))
         (sensitivity (and tool (chat-forged-tool-sensitivity tool)))
         (effects (and tool (chat-forged-tool-effects tool)))
         (predicate (and tool (chat-forged-tool-approval-predicate tool))))
    (or (memq tool-id chat-approval-required-tools)
        (memq sensitivity chat-approval-required-sensitivities)
        (seq-some (lambda (effect)
                    (memq effect chat-approval-required-effects))
                  effects)
        (and predicate (funcall predicate call)))))

(defun chat-approval-shortcut-summary (tool-id &optional directory)
  "Return a human-readable shortcut summary for TOOL-ID and DIRECTORY."
  (mapconcat #'identity
             (chat-approval--action-hints tool-id directory)
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
(defun chat-approval--prompt (tool-id arguments &optional directory)
  "Build an approval prompt for TOOL-ID with ARGUMENTS and DIRECTORY."
  (format "Approve %s risk tool %s with %s? Shortcuts: %s. "
          (chat-approval--risk-level tool-id)
          tool-id
          (chat-approval--summarize-arguments arguments)
          (chat-approval-shortcut-summary tool-id directory)))

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

(defun chat-approval--auto-approval-decision (tool-id arguments &optional session)
  "Return auto-approval metadata for TOOL-ID, ARGUMENTS, and SESSION."
  (cond
   ((chat-approval--auto-approve-p tool-id session)
    (list :decision 'auto))
   ((when-let ((directory (chat-approval--whitelisted-directory-match tool-id arguments)))
      (list :decision 'whitelisted-directory
            :directory directory)))))

(defun chat-approval--notify (observer event)
  "Send EVENT to OBSERVER."
  (when observer
    (funcall observer event)))

(defun chat-approval--command-from-arguments (arguments)
  "Return shell command string from ARGUMENTS when present."
  (cdr (assoc "command" arguments)))

(defun chat-approval--decision-options (tool-id &optional directory)
  "Return available decisions for TOOL-ID and DIRECTORY."
  (append
   '(("allow once" . allow-once)
     ("allow for session" . allow-session)
     ("always allow this tool" . allow-tool))
   (when directory
     (list (cons (format "always allow this directory (%s)" directory)
                 'allow-directory)))
   (when (eq tool-id 'shell_execute)
     '(("always allow this command" . allow-command)))
   '(("deny" . deny))))

(defun chat-approval--action-hints (tool-id &optional directory)
  "Return display strings for TOOL-ID approval shortcuts and DIRECTORY."
  (append
   '("C-c C-a once"
     "C-c C-s session"
     "C-c C-t tool")
   (when directory
     '("C-c C-f directory"))
   (when (eq tool-id 'shell_execute)
     '("C-c C-c command"))
   '("C-c C-d deny")))

(defun chat-approval--event-context (tool-id arguments)
  "Return shared event context for TOOL-ID and ARGUMENTS."
  (let ((command (chat-approval--command-from-arguments arguments))
        (directory (chat-approval--directory-scope tool-id arguments)))
    (append
     (list :risk (chat-approval--risk-level tool-id))
     (list :actions (chat-approval--action-hints tool-id directory))
     (when directory
       (list :directory directory))
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

(defun chat-approval-allow-directory ()
  "Always approve the current pending directory for file-write tools."
  (interactive)
  (chat-approval--set-pending-decision 'allow-directory))

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
  (local-set-key (kbd "C-c C-f") #'chat-approval-allow-directory)
  (local-set-key (kbd "C-c C-c") #'chat-approval-allow-command)
  (local-set-key (kbd "C-c C-d") #'chat-approval-deny))

(defun chat-approval--prompt-for-decision (tool-id arguments)
  "Prompt for TOOL-ID with ARGUMENTS and return a decision symbol."
  (let* ((directory (chat-approval--directory-scope tool-id arguments))
         (chat-approval--pending-request
          (list :tool-id tool-id
                :arguments arguments
                :directory directory))
         (choices (chat-approval--decision-options tool-id directory))
         (chat-approval--pending-request
          (append chat-approval--pending-request
                  (list :options choices)))
         (chat-approval--pending-decision nil)
         choice)
    (unwind-protect
        (progn
          (setq choice
                (minibuffer-with-setup-hook
                    #'chat-approval--install-minibuffer-bindings
                  (completing-read
                   (chat-approval--prompt tool-id arguments directory)
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
    ('allow-directory
     (when-let ((directory (chat-approval--directory-scope tool-id arguments)))
       (unless (member directory chat-approval-always-approve-directories)
         (push directory chat-approval-always-approve-directories))
       t))
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
         (directory (chat-approval--directory-scope tool-id arguments))
         (prompt (chat-approval--prompt tool-id arguments directory))
         (auto-decision (chat-approval--auto-approval-decision
                         tool-id arguments session)))
    (cond
     ((not chat-approval-enabled) t)
     ((not (chat-approval-tool-required-p tool call)) t)
     (auto-decision
      (chat-approval--notify
       observer
       (append
        (list :type 'approval
              :tool (symbol-name tool-id)
              :decision (plist-get auto-decision :decision)
              :approved t)
        (when-let ((directory (plist-get auto-decision :directory)))
          (list :directory directory))
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
              :options (chat-approval--decision-options tool-id directory))
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
        (when (eq decision 'allow-directory)
          (when-let ((directory (chat-approval--directory-scope tool-id arguments)))
            (chat-approval--notify
             observer
             (list :type 'whitelist-update
                   :tool (symbol-name tool-id)
                   :scope 'directory
                   :pattern directory
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
