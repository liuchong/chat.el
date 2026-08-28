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
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'url)
(require 'chat-files)
(require 'chat-agent-profile)
(require 'chat-session)
(require 'chat-tool-forge)
(require 'chat-work)

(defvar chat-capability-mail-drafts nil
  "Local mail draft records.  Sending is intentionally not implemented.")

(defconst chat-capability-programming-tools
  '(programming_git_status
    programming_flymake_diagnostics
    programming_compile_task
    programming_completion_at_point
    programming_verification_plan
    programming_verification_run
    programming_verification_read_result
    web_eww_read
    files_read files_read_lines files_list files_grep open_file
    files_write files_replace files_patch apply_patch
    emacs_buffers emacs_read_buffer emacs_imenu emacs_xref emacs_project)
  "Tools exposed by the programming profile.")

(defconst chat-capability-office-tools
  '(office_org_headlines
    office_org_agenda
    office_org_capture
    office_org_todo_update
    office_org_schedule
    office_dired_list
    office_dired_open
    office_dired_copy
    office_dired_mkdir
    office_dired_rename
    office_calc_eval
    office_calc_convert
    files_read files_read_lines open_file)
  "Tools exposed by the office profile.")

(defconst chat-capability-daily-tools
  '(daily_calendar_today
    web_eww_read
    daily_diary_read
    daily_diary_insert
    daily_notify
    daily_mail_draft_create
    daily_message_draft_buffer
    daily_mail_draft_list
    daily_mail_draft_delete)
  "Tools exposed by the daily profile.")

(defconst chat-capability-review-tools
  '(programming_git_status
    programming_flymake_diagnostics
    programming_completion_at_point
    files_read files_read_lines files_list files_grep open_file
    emacs_buffers emacs_read_buffer emacs_imenu emacs_xref emacs_project)
  "Read-only tools exposed by the review profile.")

(defun chat-capability-register-profiles ()
  "Register the built-in capability packs as agent profiles."
  (dolist (entry
           `((code ,chat-capability-programming-tools)
             (office ,chat-capability-office-tools)
             (daily ,chat-capability-daily-tools)
             (review ,chat-capability-review-tools)))
    (chat-agent-profile-register
     (chat-agent-profile-create
      :id (car entry)
      :revision "1"
      :tools (cadr entry)
      :tools-specified-p t
      :source 'builtin)))
  (chat-agent-profile-register
   (chat-agent-profile-create
    :id 'all :revision "1" :source 'builtin))
  t)

(defun chat-capability-profile-tools (profile)
  "Return tools for PROFILE."
  (pcase profile
    ('code chat-capability-programming-tools)
    ('office chat-capability-office-tools)
    ('daily chat-capability-daily-tools)
    ('review chat-capability-review-tools)
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

(chat-capability-register-profiles)

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

(defun chat-capability--json-string-list (value label)
  "Decode VALUE as a JSON string list named LABEL."
  (if (or (null value) (string-empty-p value))
      nil
    (let ((items (json-parse-string value :array-type 'list)))
      (unless (and (listp items) (cl-every #'stringp items))
        (error "%s must be a JSON string array" label))
      items)))

(defun chat-capability-programming-verification-plan
    (project-root &optional changed-files-json)
  "Plan project verification without running it."
  (require 'chat-code-verify)
  (chat-code-verify-profile-to-alist
   (chat-code-verify-plan
    project-root
    (chat-capability--json-string-list changed-files-json "changed_files_json")
    (chat-capability--verification-context))))

(defun chat-capability--verification-context ()
  "Return correlation fields for the current capability session."
  (let* ((session (ignore-errors (chat-capability--current-session)))
         (context (copy-sequence
                   (and (boundp 'chat-tool-caller-current-execution-context)
                        chat-tool-caller-current-execution-context))))
    (when session
      (setq context
            (plist-put context :session-id (chat-session-id session))))
    context))

(defun chat-capability-programming-verification-run (profile-id)
  "Run cached verification PROFILE-ID synchronously."
  (require 'chat-code-verify)
  (let ((profile (chat-code-verify-get-profile profile-id)))
    (unless profile (error "Unknown verification profile: %s" profile-id))
    (chat-code-verify-result-data
     (chat-code-verify-run-sync
      profile (chat-capability--verification-context)))))

(defun chat-capability-programming-verification-run-async
    (argv success error-callback)
  "Run a verification profile from tool ARGV asynchronously."
  (require 'chat-code-verify)
  (let* ((profile-id (car argv))
         (profile (chat-code-verify-get-profile profile-id))
         (context (chat-capability--verification-context)))
    (if (not profile)
        (progn
          (funcall error-callback
                   (format "Unknown verification profile: %s" profile-id))
          nil)
      (apply
       #'chat-code-verify-run profile
       (append
        context
        (list :on-complete
              (lambda (result)
                (funcall success
                         (chat-code-verify-result-data result)))))))))

(defun chat-capability-programming-verification-read-result (verification-id)
  "Read typed verification result VERIFICATION-ID."
  (require 'chat-code-verify)
  (if-let* ((result (chat-code-verify-get verification-id)))
      (chat-code-verify-result-data result)
    (error "Unknown verification result: %s" verification-id)))

(defun chat-capability-programming-completion-at-point
    (path line column &optional limit)
  "Return completion candidates at PATH LINE and COLUMN."
  (let* ((safe (chat-files--safe-path-p path))
         (existing (get-file-buffer safe))
         (buffer (find-file-noselect safe))
         result)
    (unwind-protect
        (with-current-buffer buffer
          (save-excursion
            (goto-char (point-min))
            (forward-line (max 0 (1- line)))
            (move-to-column (max 0 column))
            (let ((completion
                   (run-hook-with-args-until-success
                    'completion-at-point-functions)))
              (unless (and (listp completion)
                           (integer-or-marker-p (nth 0 completion))
                           (integer-or-marker-p (nth 1 completion)))
                (error "No completion source at %s:%d:%d"
                       safe line column))
              (let* ((start (nth 0 completion))
                     (end (nth 1 completion))
                     (collection (nth 2 completion))
                     (properties (nthcdr 3 completion))
                     (predicate (plist-get properties :predicate))
                     (prefix (buffer-substring-no-properties start end))
                     (candidates
                      (all-completions prefix collection predicate)))
                (setq result
                      `((path . ,safe)
                        (line . ,line)
                        (column . ,column)
                        (prefix . ,prefix)
                        (candidates
                         . ,(seq-take candidates (or limit 100)))))))))
      (when (and (not existing) (buffer-live-p buffer)
                 (not (buffer-modified-p buffer)))
        (kill-buffer buffer)))
    result))

(defun chat-capability-web-eww-read (url &optional max-chars)
  "Render HTTP(S) URL with the Emacs web rendering stack."
  (unless (string-match-p "\\`https?://" url)
    (error "Only HTTP(S) URLs are supported"))
  (require 'eww)
  (let ((source (url-retrieve-synchronously url t t 15))
        (limit (or max-chars 20000)))
    (unless source
      (error "Unable to retrieve URL: %s" url))
    (unwind-protect
        (with-current-buffer source
          (chat-capability--web-render-current-buffer url limit))
      (kill-buffer source))))

(defun chat-capability--web-render-current-buffer (url limit)
  "Render the current HTTP buffer for URL within LIMIT."
  (goto-char (point-min))
  (unless (re-search-forward "\r?\n\r?\n" nil t)
    (error "Malformed HTTP response"))
  (let ((body-start (point)))
    (shr-render-region body-start (point-max))
    (let ((text (string-trim
                 (buffer-substring-no-properties
                  body-start (point-max)))))
      `((url . ,url)
        (content . ,(if (> (length text) limit)
                        (concat (substring text 0 limit)
                                "\n... [truncated]")
                      text))))))

(defun chat-capability-web-eww-read-async (argv success error-callback)
  "Render a web page from tool ARGV without blocking Emacs."
  (pcase-let ((`(,url ,max-chars) argv))
    (if (not (string-match-p "\\`https?://" url))
        (progn
          (funcall error-callback "Only HTTP(S) URLs are supported")
          nil)
      (require 'eww)
      (let ((limit (or max-chars 20000))
            (done nil)
            buffer
            timer)
        (setq
         buffer
         (url-retrieve
          url
          (lambda (status)
            (unless done
              (setq done t)
              (when (timerp timer) (cancel-timer timer))
              (unwind-protect
                  (if-let ((failure (plist-get status :error)))
                      (funcall error-callback (format "%s" failure))
                    (condition-case err
                        (funcall
                         success
                         (chat-capability--web-render-current-buffer
                          url limit))
                      (error
                       (funcall error-callback
                                (error-message-string err)))))
                (when (buffer-live-p (current-buffer))
                  (kill-buffer (current-buffer))))))))
        (unless done
          (setq timer
                (run-at-time
                 20 nil
                 (lambda ()
                   (unless done
                     (setq done t)
                     (when (buffer-live-p buffer) (kill-buffer buffer))
                     (funcall error-callback
                              "Timed out retrieving web page"))))))
        (list :cancel
              (lambda ()
                (unless done
                  (setq done t)
                  (when (timerp timer) (cancel-timer timer))
                  (when (buffer-live-p buffer)
                    (kill-buffer buffer)))))))))

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

(defun chat-capability--org-paths (paths-json)
  "Decode and validate Org file PATHS-JSON."
  (let* ((json-array-type 'list)
         (paths (json-read-from-string paths-json)))
    (unless (and (listp paths) (cl-every #'stringp paths))
      (error "Org paths must be a JSON string array"))
    (mapcar #'chat-files--safe-path-p paths)))

(defun chat-capability-office-org-agenda (paths-json &optional date)
  "Return TODO, schedule, and deadline entries from PATHS-JSON.
When DATE is non-nil, keep entries whose timestamp contains DATE."
  (require 'org)
  (require 'org-element)
  (let (entries)
    (dolist (path (chat-capability--org-paths paths-json))
      (with-temp-buffer
        (insert-file-contents path)
        (org-mode)
        (org-element-map (org-element-parse-buffer) 'headline
          (lambda (headline)
            (let* ((todo (org-element-property :todo-keyword headline))
                   (scheduled (org-element-property :scheduled headline))
                   (deadline (org-element-property :deadline headline))
                   (scheduled-text
                    (and scheduled
                         (org-element-property :raw-value scheduled)))
                   (deadline-text
                    (and deadline
                         (org-element-property :raw-value deadline))))
              (when (and (or todo scheduled deadline)
                         (or (null date)
                             (string-match-p
                              (regexp-quote date)
                              (concat (or scheduled-text "") " "
                                      (or deadline-text "")))))
                (push `((path . ,path)
                        (line . ,(line-number-at-pos
                                  (org-element-property :begin headline)))
                        (title . ,(org-element-property :raw-value headline))
                        (todo . ,todo)
                        (scheduled . ,scheduled-text)
                        (deadline . ,deadline-text))
                      entries)))))))
    (nreverse entries)))

(defun chat-capability-office-org-capture
    (path title &optional body status)
  "Append an Org heading with TITLE, BODY, and optional STATUS to PATH."
  (let ((safe (chat-files--safe-path-p path)))
    (with-temp-buffer
      (when (file-exists-p safe)
        (insert-file-contents safe))
      (goto-char (point-max))
      (unless (or (bobp) (eq (char-before) ?\n))
        (insert "\n"))
      (insert "* "
              (if (and status (not (string-empty-p status)))
                  (concat status " ")
                "")
              title "\n")
      (when (and body (not (string-empty-p body)))
        (insert body "\n"))
      (write-region (point-min) (point-max) safe nil 'silent))
    `((path . ,safe) (title . ,title) (captured . t))))

(defun chat-capability--org-find-heading (title)
  "Move point to exact Org heading TITLE."
  (goto-char (point-min))
  (unless (re-search-forward
           (format "^\\*+[ \t]+\\(?:[[:upper:]][[:upper:]_-]*[ \t]+\\)?%s[ \t]*$"
                   (regexp-quote title))
           nil t)
    (error "Org heading not found: %s" title))
  (beginning-of-line))

(defun chat-capability-office-org-todo-update (path title status)
  "Set Org heading TITLE in PATH to TODO STATUS."
  (require 'org)
  (let ((safe (chat-files--safe-path-p path))
        (org-log-done nil))
    (with-current-buffer (find-file-noselect safe)
      (org-mode)
      (save-excursion
        (chat-capability--org-find-heading title)
        (org-todo status)
        (save-buffer)))
    `((path . ,safe) (title . ,title) (status . ,status))))

(defun chat-capability-office-org-schedule (path title date)
  "Schedule Org heading TITLE in PATH for DATE."
  (require 'org)
  (let ((safe (chat-files--safe-path-p path)))
    (with-current-buffer (find-file-noselect safe)
      (org-mode)
      (save-excursion
        (chat-capability--org-find-heading title)
        (org-schedule nil date)
        (save-buffer)))
    `((path . ,safe) (title . ,title) (scheduled . ,date))))

(defun chat-capability-office-dired-list (directory)
  "Return a Dired-style listing for DIRECTORY."
  (let ((safe (chat-files--safe-path-p directory)))
    (mapcar (lambda (name)
              (let ((path (expand-file-name name safe)))
                `((name . ,name)
                  (type . ,(if (file-directory-p path) "directory" "file")))))
            (directory-files safe nil directory-files-no-dot-files-regexp))))

(defun chat-capability-office-dired-open (path)
  "Open PATH in an Emacs file or Dired buffer."
  (let* ((safe (chat-files--safe-path-p path))
         (buffer (find-file-noselect safe)))
    `((path . ,safe)
      (buffer . ,(buffer-name buffer))
      (mode . ,(symbol-name
                (buffer-local-value 'major-mode buffer))))))

(defun chat-capability-office-dired-copy (source target)
  "Copy SOURCE to TARGET without overwriting."
  (let ((from (chat-files--safe-path-p source))
        (to (chat-files--safe-path-p target)))
    (if (file-directory-p from)
        (copy-directory from to nil nil nil)
      (copy-file from to nil))
    `((source . ,from) (target . ,to) (copied . t))))

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

(defun chat-capability-office-calc-convert (value target-unit)
  "Convert Calc VALUE to TARGET-UNIT."
  (require 'calc)
  (require 'calc-units)
  (math-format-value
   (math-convert-units
    (math-read-expr value)
    (math-read-expr target-unit))))

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

(defun chat-capability-daily-message-draft-buffer (to subject body)
  "Create an unsent `message-mode' draft buffer."
  (require 'message)
  (let* ((draft (chat-capability-daily-mail-draft-create
                 to subject body))
         (buffer (generate-new-buffer
                  (format "*chat-draft-%s*"
                          (cdr (assoc 'id draft))))))
    (with-current-buffer buffer
      (message-mode)
      (insert (format "To: %s\nSubject: %s\n\n%s"
                      to subject body))
      (goto-char (point-min)))
    (append draft `((buffer . ,(buffer-name buffer))))))

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
    (id name description parameters fn sensitivity effects
        &optional async-fn)
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
    :async-function async-fn
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
   'programming_completion_at_point "Programming Completion At Point"
   "Return native completion candidates at a file position."
   '((:name "path" :type "string" :required t)
     (:name "line" :type "integer" :required t)
     (:name "column" :type "integer" :required t)
     (:name "limit" :type "integer" :required nil))
   #'chat-capability-programming-completion-at-point 'project '(read))
  (chat-capability--register-tool
   'programming_verification_plan "Programming Verification Plan"
   "Resolve deterministic project checks without executing them."
   '((:name "project_root" :type "string" :required t)
     (:name "changed_files_json" :type "string" :required nil))
   #'chat-capability-programming-verification-plan 'project '(read))
  (chat-capability--register-tool
   'programming_verification_run "Programming Verification Run"
   "Run an existing verification plan with bounded output and timeout."
   '((:name "profile_id" :type "string" :required t))
   #'chat-capability-programming-verification-run 'project '(read)
   #'chat-capability-programming-verification-run-async)
  (chat-capability--register-tool
   'programming_verification_read_result "Programming Verification Result"
   "Read the structured evidence for a verification run."
   '((:name "verification_id" :type "string" :required t))
   #'chat-capability-programming-verification-read-result 'project '(read))
  (chat-capability--register-tool
   'web_eww_read "Web EWW Read"
   "Retrieve and render an HTTP(S) page with the Emacs web stack."
   '((:name "url" :type "string" :required t)
     (:name "max_chars" :type "integer" :required nil))
   #'chat-capability-web-eww-read 'network '(read outbound)
   #'chat-capability-web-eww-read-async)
  (chat-capability--register-tool
   'office_org_headlines "Office Org Headlines"
   "Read Org headlines from a file."
   '((:name "path" :type "string" :required t))
   #'chat-capability-office-org-headlines 'project '(read))
  (chat-capability--register-tool
   'office_org_agenda "Office Org Agenda"
   "List TODO, scheduled, and deadline entries from Org files."
   '((:name "paths_json" :type "string" :required t)
     (:name "date" :type "string" :required nil))
   #'chat-capability-office-org-agenda 'personal '(read))
  (chat-capability--register-tool
   'office_org_capture "Office Org Capture"
   "Append a heading to an Org file."
   '((:name "path" :type "string" :required t)
     (:name "title" :type "string" :required t)
     (:name "body" :type "string" :required nil)
     (:name "status" :type "string" :required nil))
   #'chat-capability-office-org-capture 'personal '(write))
  (chat-capability--register-tool
   'office_org_todo_update "Office Org Todo Update"
   "Set the TODO state of an exact Org heading."
   '((:name "path" :type "string" :required t)
     (:name "title" :type "string" :required t)
     (:name "status" :type "string" :required t))
   #'chat-capability-office-org-todo-update 'personal '(write))
  (chat-capability--register-tool
   'office_org_schedule "Office Org Schedule"
   "Schedule an exact Org heading for a date."
   '((:name "path" :type "string" :required t)
     (:name "title" :type "string" :required t)
     (:name "date" :type "string" :required t))
   #'chat-capability-office-org-schedule 'personal '(write))
  (chat-capability--register-tool
   'office_dired_list "Office Dired List"
   "List files in a directory."
   '((:name "directory" :type "string" :required t))
   #'chat-capability-office-dired-list 'project '(read))
  (chat-capability--register-tool
   'office_dired_open "Office Dired Open"
   "Open a file or directory in an Emacs buffer."
   '((:name "path" :type "string" :required t))
   #'chat-capability-office-dired-open 'project '(read))
  (chat-capability--register-tool
   'office_dired_copy "Office Dired Copy"
   "Copy a file or directory without overwriting."
   '((:name "source" :type "string" :required t)
     (:name "target" :type "string" :required t))
   #'chat-capability-office-dired-copy 'project '(write))
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
   'office_calc_convert "Office Calc Convert"
   "Convert a Calc value to a target unit."
   '((:name "value" :type "string" :required t)
     (:name "target_unit" :type "string" :required t))
   #'chat-capability-office-calc-convert 'public '(read))
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
   'daily_message_draft_buffer "Daily Message Draft Buffer"
   "Create an unsent message-mode draft buffer."
   '((:name "to" :type "string" :required t)
     (:name "subject" :type "string" :required t)
     (:name "body" :type "string" :required t))
   #'chat-capability-daily-message-draft-buffer
   'correspondence '(write))
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
