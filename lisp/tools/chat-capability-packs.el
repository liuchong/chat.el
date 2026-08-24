;;; chat-capability-packs.el --- Scoped capability packs for chat.el -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: chat, tools, capabilities

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Emacs-first programming, office, and daily capability packs.  Profiles
;; use session tool overlays so each surface can advertise a relevant
;; subset of tools.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'chat-files)
(require 'chat-session)
(require 'chat-tool-forge)
(require 'chat-work)

(defvar chat-capability-mail-drafts nil
  "Local mail draft records.  Sending is intentionally not implemented.")

(defconst chat-capability-programming-tools
  '(programming_git_status
    programming_flymake_diagnostics
    programming_compile_task
    files_read files_read_lines files_list files_grep open_file
    files_write files_replace files_patch apply_patch
    emacs_buffers emacs_read_buffer emacs_imenu emacs_xref emacs_project)
  "Tools exposed by the programming profile.")

(defconst chat-capability-office-tools
  '(office_org_headlines
    office_dired_list
    office_dired_mkdir
    office_dired_rename
    office_calc_eval
    files_read files_read_lines open_file)
  "Tools exposed by the office profile.")

(defconst chat-capability-daily-tools
  '(daily_calendar_today
    daily_diary_read
    daily_diary_insert
    daily_notify
    daily_mail_draft_create
    daily_mail_draft_list
    daily_mail_draft_delete)
  "Tools exposed by the daily profile.")

(defun chat-capability-profile-tools (profile)
  "Return tools for PROFILE."
  (pcase profile
    ('code chat-capability-programming-tools)
    ('office chat-capability-office-tools)
    ('daily chat-capability-daily-tools)
    ('all nil)
    (_ (error "Unknown capability profile: %s" profile))))

(defun chat-capability-apply-profile (session profile)
  "Apply capability PROFILE to SESSION using session tool overlays."
  (let ((tools (chat-capability-profile-tools profile)))
    (chat-session-set-tool-config
     session
     (if tools
         (list :profile profile :enabled-tools tools)
       (list :profile profile)))
    session))

(defun chat-capability--current-session ()
  "Return the current chat session for interactive profile commands."
  (or (and (boundp 'chat--current-session) chat--current-session)
      (and (boundp 'chat-tool-caller-current-session)
           chat-tool-caller-current-session)
      (error "No current chat session")))

;;;###autoload
(defun chat-capability-profile-code (&optional session)
  "Apply the code capability profile to SESSION."
  (interactive)
  (chat-capability-apply-profile
   (or session (chat-capability--current-session))
   'code))

;;;###autoload
(defun chat-capability-profile-office (&optional session)
  "Apply the office capability profile to SESSION."
  (interactive)
  (chat-capability-apply-profile
   (or session (chat-capability--current-session))
   'office))

;;;###autoload
(defun chat-capability-profile-daily (&optional session)
  "Apply the daily capability profile to SESSION."
  (interactive)
  (chat-capability-apply-profile
   (or session (chat-capability--current-session))
   'daily))

(defun chat-capability-programming-git-status (&optional directory)
  "Return read-only git status for DIRECTORY."
  (let ((default-directory (file-name-as-directory
                            (or directory default-directory))))
    (with-temp-buffer
      (let ((exit (process-file "git" nil t nil "status" "--short")))
        (if (zerop exit)
            (buffer-string)
          (format "git status failed with exit %s\n%s"
                  exit (buffer-string)))))))

(defun chat-capability-programming-flymake-diagnostics ()
  "Return Flymake diagnostics for the current buffer when available."
  (if (not (fboundp 'flymake-diagnostics))
      "Flymake is unavailable."
    (let ((diagnostics (flymake-diagnostics (point-min) (point-max))))
      (if (null diagnostics)
          "No Flymake diagnostics."
        (string-join
         (mapcar (lambda (diag)
                   (format "%s:%s:%s %s"
                           (line-number-at-pos (flymake-diagnostic-beg diag))
                           (or (flymake-diagnostic-type diag) 'unknown)
                           (or (flymake-diagnostic-text diag) "")
                           (or (flymake-diagnostic-buffer diag)
                               (current-buffer))))
                 diagnostics)
         "\n")))))

(defun chat-capability-programming-compile-task (command &optional directory)
  "Start compile/test COMMAND as a background task."
  (chat-work-task-start command (or directory default-directory)))

(defun chat-capability-office-org-headlines (path)
  "Return Org headlines from PATH."
  (let ((safe (chat-files--safe-path-p path))
        headlines)
    (with-temp-buffer
      (insert-file-contents safe)
      (goto-char (point-min))
      (while (re-search-forward "^\\(\\*+\\)[ \t]+\\(.*\\)$" nil t)
        (push `((level . ,(length (match-string 1)))
                (title . ,(match-string 2))
                (line . ,(line-number-at-pos)))
              headlines)))
    (nreverse headlines)))

(defun chat-capability-office-dired-list (directory)
  "Return a Dired-style listing for DIRECTORY."
  (let ((safe (chat-files--safe-path-p directory)))
    (mapcar (lambda (name)
              (let ((path (expand-file-name name safe)))
                `((name . ,name)
                  (type . ,(if (file-directory-p path) "directory" "file")))))
            (directory-files safe nil directory-files-no-dot-files-regexp))))

(defun chat-capability-office-dired-mkdir (directory)
  "Create DIRECTORY after approval."
  (let ((safe (chat-files--safe-path-p directory)))
    (make-directory safe t)
    `((path . ,safe) (created . t))))

(defun chat-capability-office-dired-rename (source target)
  "Rename SOURCE to TARGET after approval."
  (let ((from (chat-files--safe-path-p source))
        (to (chat-files--safe-path-p target)))
    (rename-file from to)
    `((source . ,from) (target . ,to) (renamed . t))))

(defun chat-capability-office-calc-eval (expression)
  "Evaluate pure Calc EXPRESSION."
  (require 'calc)
  (calc-eval expression))

(defun chat-capability-daily-calendar-today ()
  "Return today's date in calendar-friendly form."
  `((date . ,(format-time-string "%Y-%m-%d"))
    (weekday . ,(format-time-string "%A"))))

(defun chat-capability-daily-diary-read (&optional path)
  "Read diary file PATH or `diary-file'."
  (let ((file (chat-files--safe-path-p
               (or path (bound-and-true-p diary-file)))))
    (with-temp-buffer
      (insert-file-contents file)
      (buffer-string))))

(defun chat-capability-daily-diary-insert (entry &optional path)
  "Append diary ENTRY to PATH or `diary-file'."
  (let ((file (chat-files--safe-path-p
               (or path (bound-and-true-p diary-file)))))
    (write-region (concat entry "\n") nil file 'append 'silent)
    `((path . ,file) (inserted . t))))

(defun chat-capability-daily-notify (title body)
  "Send or record a local notification with TITLE and BODY."
  (if (fboundp 'notifications-notify)
      (notifications-notify :title title :body body)
    (message "%s: %s" title body))
  `((title . ,title) (body . ,body) (notified . t)))

(defun chat-capability-daily-mail-draft-create (to subject body)
  "Create a local mail draft.  This never sends mail."
  (let ((draft `((id . ,(chat-session-new-message-id "mail-draft"))
                 (to . ,to)
                 (subject . ,subject)
                 (body . ,body)
                 (status . "draft"))))
    (push draft chat-capability-mail-drafts)
    draft))

(defun chat-capability-daily-mail-draft-list ()
  "List local mail drafts."
  (nreverse (copy-tree chat-capability-mail-drafts)))

(defun chat-capability-daily-mail-draft-delete (id)
  "Delete local mail draft ID."
  (setq chat-capability-mail-drafts
        (cl-remove id chat-capability-mail-drafts
                   :key (lambda (draft) (cdr (assoc 'id draft)))
                   :test #'equal))
  `((id . ,id) (deleted . t)))

(defun chat-capability--register-tool
    (id name description parameters fn sensitivity effects)
  "Register one capability tool."
  (chat-tool-forge-register
   (make-chat-forged-tool
    :id id
    :name name
    :description description
    :language 'elisp
    :parameters parameters
    :owner 'capability-packs
    :sensitivity sensitivity
    :effects effects
    :compiled-function fn
    :is-active t
    :usage-count 0)))

(defun chat-capability-register-tools ()
  "Register programming, office, and daily capability tools."
  (chat-capability--register-tool
   'programming_git_status "Programming Git Status"
   "Return read-only git status for a directory."
   '((:name "directory" :type "string" :required nil))
   #'chat-capability-programming-git-status 'project '(read))
  (chat-capability--register-tool
   'programming_flymake_diagnostics "Programming Flymake Diagnostics"
   "Return Flymake diagnostics for the current buffer."
   nil #'chat-capability-programming-flymake-diagnostics 'project '(read))
  (chat-capability--register-tool
   'programming_compile_task "Programming Compile Task"
   "Start a compile or test command as a background task."
   '((:name "command" :type "string" :required t)
     (:name "directory" :type "string" :required nil))
   #'chat-capability-programming-compile-task 'project '(write outbound))
  (chat-capability--register-tool
   'office_org_headlines "Office Org Headlines"
   "Read Org headlines from a file."
   '((:name "path" :type "string" :required t))
   #'chat-capability-office-org-headlines 'project '(read))
  (chat-capability--register-tool
   'office_dired_list "Office Dired List"
   "List files in a directory."
   '((:name "directory" :type "string" :required t))
   #'chat-capability-office-dired-list 'project '(read))
  (chat-capability--register-tool
   'office_dired_mkdir "Office Dired Mkdir"
   "Create a directory."
   '((:name "directory" :type "string" :required t))
   #'chat-capability-office-dired-mkdir 'project '(write))
  (chat-capability--register-tool
   'office_dired_rename "Office Dired Rename"
   "Rename a file or directory."
   '((:name "source" :type "string" :required t)
     (:name "target" :type "string" :required t))
   #'chat-capability-office-dired-rename 'project '(write))
  (chat-capability--register-tool
   'office_calc_eval "Office Calc Eval"
   "Evaluate a pure Calc expression."
   '((:name "expression" :type "string" :required t))
   #'chat-capability-office-calc-eval 'public '(read))
  (chat-capability--register-tool
   'daily_calendar_today "Daily Calendar Today"
   "Return today's local date."
   nil #'chat-capability-daily-calendar-today 'public '(read))
  (chat-capability--register-tool
   'daily_diary_read "Daily Diary Read"
   "Read the diary file."
   '((:name "path" :type "string" :required nil))
   #'chat-capability-daily-diary-read 'personal '(read))
  (chat-capability--register-tool
   'daily_diary_insert "Daily Diary Insert"
   "Append an entry to the diary file."
   '((:name "entry" :type "string" :required t)
     (:name "path" :type "string" :required nil))
   #'chat-capability-daily-diary-insert 'personal '(write))
  (chat-capability--register-tool
   'daily_notify "Daily Notify"
   "Send or record a local notification."
   '((:name "title" :type "string" :required t)
     (:name "body" :type "string" :required t))
   #'chat-capability-daily-notify 'personal '(outbound))
  (chat-capability--register-tool
   'daily_mail_draft_create "Daily Mail Draft Create"
   "Create a local mail draft without sending."
   '((:name "to" :type "string" :required t)
     (:name "subject" :type "string" :required t)
     (:name "body" :type "string" :required t))
   #'chat-capability-daily-mail-draft-create 'correspondence '(write))
  (chat-capability--register-tool
   'daily_mail_draft_list "Daily Mail Draft List"
   "List local mail drafts."
   nil #'chat-capability-daily-mail-draft-list 'correspondence '(read))
  (chat-capability--register-tool
   'daily_mail_draft_delete "Daily Mail Draft Delete"
   "Delete a local mail draft."
   '((:name "id" :type "string" :required t))
   #'chat-capability-daily-mail-draft-delete 'correspondence '(write)))

(provide 'chat-capability-packs)
;;; chat-capability-packs.el ends here
