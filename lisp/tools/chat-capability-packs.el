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
(require 'chat-agent-types)
(require 'chat-agent-profile)
(require 'chat-session)
(require 'chat-tool-forge)
(require 'chat-work)
(require 'chat-work-plan)
(require 'chat-goal)
(require 'chat-plan-mode)

(defvar chat-capability-mail-drafts nil
  "Local mail draft records.  Sending is intentionally not implemented.")

(defconst chat-capability-programming-base-tools
  '(programming_capability_activate
    programming_plan_create programming_plan_skip
    programming_git_status
    files_read files_read_lines files_list files_grep open_file)
  "Initial tool menu advertised before a programming plan exists.")

(defconst chat-capability-programming-execution-tools
  '(files_write files_replace files_patch apply_patch)
  "Mutating tools advertised only after an ordinary work plan starts.")

(defconst chat-capability-programming-verification-fallback-tools
  '(programming_compile_task)
  "Generic command tools exposed only after deterministic planning finds no check.")

(defconst chat-capability-programming-background-task-tools
  '(programming_compile_task programming_task_output)
  "Complete authority for starting and observing background checks.")

(defconst chat-capability-programming-exploration-tools
  '(programming_flymake_diagnostics
    programming_completion_at_point
    web_eww_read
    emacs_buffers emacs_read_buffer emacs_imenu emacs_xref emacs_project)
  "Editor-semantic and external lookup tools activated when needed.")

(defconst chat-capability-programming-verification-tools
  '(programming_verification_plan programming_verification_run
    programming_verification_read_result)
  "Complete programming authority for the verification lifecycle.")

(defconst chat-capability-programming-verification-plan-tools
  '(programming_verification_plan)
  "Verification tools available before a profile handle exists.")

(defconst chat-capability-programming-verification-run-tools
  '(programming_verification_run)
  "Verification tools available after planning returns a profile handle.")

(defconst chat-capability-programming-verification-result-tools
  '(programming_verification_read_result)
  "Verification tools available after a run creates a result handle.")

(defconst chat-capability-programming-work-note-tools
  '(programming_work_note_upsert programming_work_note_query
    programming_work_note_resolve programming_work_note_supersede
    programming_work_note_archive programming_work_note_delete)
  "Programming tools advertised for structured working notes.")

(defconst chat-capability-programming-context-tools
  '(programming_context_inspect)
  "Programming tools advertised for scoped context inspection.")

(defconst chat-capability-programming-goal-tools
  '(programming_goal_create programming_goal_read programming_goal_list
    programming_goal_progress programming_goal_block programming_goal_complete)
  "Programming tools advertised for durable Goal work.")

(defconst chat-capability-programming-plan-tools
  '(programming_plan_mode_enter programming_plan_create programming_plan_read
    programming_plan_list programming_plan_update programming_plan_submit
    programming_plan_transition programming_plan_resume programming_plan_cancel
    programming_plan_skip programming_plan_mode)
  "Programming tools advertised for TODO plans and Plan Mode.")

(defconst chat-capability-programming-bounded-plan-tools
  '(programming_plan_create programming_plan_read programming_plan_list)
  "Plan tools retained while one bounded mutation is being resolved.")

(defconst chat-capability-programming-tool-groups
  `((exploration . ,chat-capability-programming-exploration-tools)
    (plan . ,chat-capability-programming-plan-tools)
    (goal . ,chat-capability-programming-goal-tools)
    (notes . ,chat-capability-programming-work-note-tools)
    (verification . ,chat-capability-programming-verification-tools)
    (context . ,chat-capability-programming-context-tools))
  "On-demand programming tool groups keyed by activation name.")

(defconst chat-capability-programming-tools
  (delete-dups
   (apply #'append
          (copy-sequence chat-capability-programming-base-tools)
          (copy-sequence chat-capability-programming-execution-tools)
          (copy-sequence chat-capability-programming-background-task-tools)
          (mapcar (lambda (entry) (copy-sequence (cdr entry)))
                  chat-capability-programming-tool-groups)))
  "Complete programming authority; only a stage-relevant subset is advertised.")

(defconst chat-capability--work-plan-item-schema
  '((type . "object")
    (properties
     . (("id" . ((type . "string")
                  (description . "Stable item id used by dependencies.")))
        ("title" . ((type . "string")
                     (description . "One concrete implementation step.")))
        ("acceptance" . ((type . "string")
                          (description . "Observable evidence that completes this step.")))
        ("dependencies" . ((type . "array")
                            (description . "Ids of prerequisite items.")
                            (items . ((type . "string")))))))
    (required . ["title" "acceptance"])
    (additionalProperties . :json-false))
  "Provider schema for one durable work-plan item.")

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
    programming_review_diff
    programming_review_repo_map
    programming_flymake_diagnostics
    programming_verification_read_result
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

(defun chat-capability--ordered-tool-union (&rest groups)
  "Return GROUPS as one stable duplicate-free tool list."
  (let (result)
    (dolist (group groups result)
      (dolist (tool group)
        (unless (memq tool result)
          (setq result (append result (list tool))))))))

(defun chat-capability--verification-stage-tools (session)
  "Return verification tools whose prerequisite handles exist for SESSION."
  (let ((tools chat-capability-programming-verification-plan-tools))
    (when (and session (require 'chat-code-verify nil t))
      (let ((session-id (chat-session-id session))
            (task-id (chat-capability--verification-task-id session)))
        (when-let* ((profile
                     (chat-code-verify-latest-profile-for-context
                      session-id task-id))
                    ((chat-verification-profile-steps profile)))
          (setq tools
                (chat-capability--ordered-tool-union
                 tools chat-capability-programming-verification-run-tools)))
        (when (chat-code-verify-latest-result-for-context session-id task-id)
          (setq tools
                (chat-capability--ordered-tool-union
                 tools chat-capability-programming-verification-result-tools)))))
    tools))

(defun chat-capability-programming-tool-advertisement
    (session profile authorized-tools)
  "Select the stage-relevant programming tools for SESSION and PROFILE."
  (when (eq (chat-agent-profile-id profile) 'code)
    (let* ((advertised
            (copy-sequence chat-capability-programming-base-tools))
           (plan (and session
                      (ignore-errors (chat-work-plan-current session))))
           (bounded-skip
            (and session
                 (ignore-errors
                   (chat-work-plan-bounded-skip-state session))))
           (plan-mode (and session
                           (ignore-errors (chat-plan-mode-active-p session))))
           (ordinary-execution
            (and plan (not plan-mode)
                 (eq (chat-work-plan-status plan) 'active)
                 (seq-some
                  (lambda (item)
                    (eq (chat-work-plan-item-status item) 'in-progress))
                  (chat-work-plan-items plan))))
           (bounded-verification
            (and bounded-skip
                 (> (or (plist-get bounded-skip :consumed-count) 0) 0))))
      (when (or plan plan-mode)
        (setq advertised
              (chat-capability--ordered-tool-union
               advertised chat-capability-programming-plan-tools)))
      (when (and plan (eq (chat-work-plan-status plan) 'active))
        (setq advertised (delq 'programming_plan_create advertised)))
      (when ordinary-execution
        (setq advertised
              (chat-capability--ordered-tool-union
               advertised chat-capability-programming-execution-tools
               (chat-capability--verification-stage-tools session))))
      (when bounded-skip
        (setq advertised
              (seq-remove
               (lambda (tool)
                 (or (eq tool 'programming_capability_activate)
                     (and (memq tool chat-capability-programming-plan-tools)
                          (not (memq
                                tool
                                chat-capability-programming-bounded-plan-tools)))))
               advertised))
        (setq advertised
              (chat-capability--ordered-tool-union
               advertised chat-capability-programming-bounded-plan-tools))
        (let ((tool-name (plist-get bounded-skip :tool-name))
              (consumed-count
               (plist-get bounded-skip :consumed-count)))
          (if (= consumed-count 0)
              (when-let ((tool (intern-soft tool-name))
                         ((memq tool authorized-tools)))
                (setq advertised
                      (chat-capability--ordered-tool-union
                       advertised (list tool))))
            (setq advertised
                  (chat-capability--ordered-tool-union
                   advertised
                   (chat-capability--verification-stage-tools session))))))
      (when (and (or ordinary-execution bounded-verification)
                 session
                 (chat-capability--verification-fallback-authorized-p session))
        (setq advertised
              (chat-capability--ordered-tool-union
               advertised
               chat-capability-programming-verification-fallback-tools)))
      (when (and session (chat-work-session-has-task-p session))
        (setq advertised
              (chat-capability--ordered-tool-union
               advertised '(programming_task_output))))
      (when (and session (ignore-errors (chat-goal-current session)))
        (setq advertised
              (chat-capability--ordered-tool-union
               advertised chat-capability-programming-goal-tools)))
      (list :advertised-tools
            (seq-filter (lambda (tool) (memq tool authorized-tools))
                        advertised)))))

(add-hook 'chat-agent-profile-tool-advertisement-functions
          #'chat-capability-programming-tool-advertisement)

(defun chat-capability-programming-refresh-tool-advertisement (run)
  "Keep bounded-skip tool menus synchronized for RUN.

Capability activation is intentionally cumulative during ordinary work.  A
bounded skip is different: it is a state-machine boundary that must replace
any previously activated menu with the exact mutation contract, then replace
that mutation with verification and Plan-upgrade tools after consumption."
  (let* ((state-session (chat-agent-run-state-session run))
         (execution-session (chat-agent-run-state-execution-session run))
         (profile (chat-agent-run-state-profile run))
         (bounded-skip
          (and state-session
               (ignore-errors
                 (chat-work-plan-bounded-skip-state state-session)))))
    (when (and execution-session
               profile
               (eq (chat-agent-profile-id profile) 'code)
               bounded-skip)
      (let* ((config (copy-tree
                      (chat-session-tool-config execution-session)))
             (enabled (plist-get config :enabled-tools))
             (disabled (plist-get config :disabled-tools))
             (selection
              (chat-capability-programming-tool-advertisement
               state-session profile enabled))
             (advertised
              (seq-remove
               (lambda (tool) (memq tool disabled))
               (plist-get selection :advertised-tools))))
        (setf (chat-session-tool-config execution-session)
              (plist-put config :advertised-tools advertised))
        advertised))))

(add-hook 'chat-plugin-pre-step-functions
          #'chat-capability-programming-refresh-tool-advertisement)

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
  (or (and (boundp 'chat-tool-caller-current-state-session)
           chat-tool-caller-current-state-session)
      (and (boundp 'chat-tool-caller-current-session)
           chat-tool-caller-current-session)
      (and (boundp 'chat--current-session) chat--current-session)
      (error "No current chat session")))

(defun chat-capability--execution-session ()
  "Return the ephemeral execution session used for provider tool menus."
  (or (and (boundp 'chat-tool-caller-current-session)
           chat-tool-caller-current-session)
      (and (boundp 'chat--current-session) chat--current-session)))

(defun chat-capability--advertise-tools (tools)
  "Advertise authorized TOOLS for the remainder of the current agent run."
  (when-let ((session (chat-capability--execution-session)))
    (let* ((config (copy-tree (chat-session-tool-config session)))
           (enabled (plist-get config :enabled-tools))
           (disabled (plist-get config :disabled-tools))
           (current (if (plist-member config :advertised-tools)
                        (plist-get config :advertised-tools)
                      enabled))
           (allowed (seq-filter
                     (lambda (tool)
                       (and (or (not (plist-member config :enabled-tools))
                                (memq tool enabled))
                            (not (memq tool disabled))))
                     tools))
           (advertised (chat-capability--ordered-tool-union current allowed)))
      (setf (chat-session-tool-config session)
            (plist-put config :advertised-tools advertised))
      allowed)))

(defun chat-capability--unadvertise-tools (tools)
  "Remove TOOLS from the current run's provider-facing menu."
  (when-let ((session (chat-capability--execution-session)))
    (let* ((config (copy-tree (chat-session-tool-config session)))
           (current (plist-get config :advertised-tools)))
      (when current
        (setf (chat-session-tool-config session)
              (plist-put
               config :advertised-tools
               (seq-remove (lambda (tool) (memq tool tools)) current)))))))

(defun chat-capability-programming-capability-activate (capability)
  "Advertise the programming tool group named CAPABILITY for this run."
  (let* ((name (intern capability))
         (tools
          (if (eq name 'verification)
              (chat-capability--verification-stage-tools
               (ignore-errors (chat-capability--current-session)))
            (alist-get name chat-capability-programming-tool-groups))))
    (unless tools
      (error "Unknown programming capability: %s" capability))
    (let ((advertised (chat-capability--advertise-tools tools)))
      `((capability . ,capability)
        (tools . ,(vconcat advertised))))))

(defun chat-capability--project-directory (&optional directory)
  "Return explicit DIRECTORY or the current session's project directory."
  (let* ((session (ignore-errors (chat-capability--current-session)))
         (project (and session (chat-session-working-directory session))))
    (file-name-as-directory
     (expand-file-name (or directory project default-directory)))))

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

(defun chat-capability-programming-review-diff
    (project-root &optional base-revision)
  "Return a bounded read-only diff for PROJECT-ROOT from BASE-REVISION."
  (require 'chat-code-review)
  (chat-code-review-read-diff project-root base-revision))

(defun chat-capability-programming-review-repo-map
    (project-root query &optional changed-files)
  "Return bounded repo-map evidence for QUERY in PROJECT-ROOT."
  (require 'chat-code-review)
  (chat-code-review-read-repo-map
   project-root query
   (chat-capability--native-string-list changed-files "changed_files")))

(defun chat-capability-programming-compile-task (command &optional directory)
  "Start compile/test COMMAND as a background task."
  (let ((task (chat-work-task-start
               command (chat-capability--project-directory directory))))
    (chat-capability--advertise-tools '(programming_task_output))
    task))

(defun chat-capability-programming-task-output
    (id &optional offset max-bytes)
  "Read structured output for compile/test task ID in the current session."
  (chat-work-task-output id offset max-bytes))

(defun chat-capability--json-string-list (value label)
  "Decode VALUE as a JSON string list named LABEL."
  (if (or (null value) (string-empty-p value))
      nil
    (let ((items (json-parse-string value :array-type 'list)))
      (unless (and (listp items) (cl-every #'stringp items))
        (error "%s must be a JSON string array" label))
      items)))

(defun chat-capability--string-list (value label)
  "Normalize native or legacy JSON string-list VALUE named LABEL."
  (let ((items
         (cond
          ((null value) nil)
          ((and (stringp value) (string-empty-p value)) nil)
          ((stringp value)
           (json-parse-string value :array-type 'list))
          ((vectorp value) (append value nil))
          ((proper-list-p value) value)
          (t (error "%s must be an array of strings" label)))))
    (unless (cl-every #'stringp items)
      (error "%s must be an array of strings" label))
    items))

(defun chat-capability--native-string-list (value label)
  "Validate native string array VALUE named LABEL."
  (let ((items
         (cond
          ((null value) nil)
          ((vectorp value) (append value nil))
          ((proper-list-p value) value)
          (t (error "%s must be an array of strings" label)))))
    (unless (cl-every #'stringp items)
      (error "%s must be an array of strings" label))
    items))

(defun chat-capability--work-plan-items (value label)
  "Normalize native or legacy JSON work-plan item VALUE named LABEL."
  (let ((items
         (cond
          ((stringp value)
           (json-parse-string value :object-type 'alist :array-type 'list
                              :null-object nil :false-object :json-false))
          ((vectorp value) (append value nil))
          ((proper-list-p value) value)
          (t (error "%s must be an array of plan item objects" label)))))
    (unless items
      (error "%s must contain at least one plan item" label))
    items))

(defun chat-capability--verification-task-id (session)
  "Return the current Agent task identity for verification in SESSION."
  (or (and (boundp 'chat-tool-caller-current-execution-context)
           (plist-get chat-tool-caller-current-execution-context :task-id))
      (and session (chat-session-metadata-get session 'activeTaskId))))

(defun chat-capability--verification-fallback-authorized-p (session)
  "Return non-nil when SESSION may use generic verification commands."
  (let ((state (and session
                    (chat-session-metadata-get
                     session 'programmingVerificationFallback))))
    (and state
         (equal (plist-get state :task-id)
                (chat-capability--verification-task-id session)))))

(defun chat-capability--set-verification-fallback (session profile)
  "Authorize generic verification in SESSION only when PROFILE has no steps."
  (if (chat-verification-profile-steps profile)
      (chat-session-metadata-set session 'programmingVerificationFallback nil)
    (chat-session-metadata-set
     session 'programmingVerificationFallback
     (list :task-id (chat-capability--verification-task-id session)
           :profile-id (chat-verification-profile-id profile)))))

(defun chat-capability-programming-verification-plan
    (project-root &optional changed-files)
  "Plan project verification without running it."
  (require 'chat-code-verify)
  (require 'chat-approval-guard)
  (let* ((session (chat-capability--current-session))
         (context (chat-capability--verification-context))
         (commands
          (chat-approval-guard-verification-commands session project-root))
         (context
          (if commands
              (plist-put context :verification-commands commands)
            context))
         (profile
          (chat-code-verify-plan
           project-root
           (chat-capability--native-string-list
            changed-files "changed_files")
           context)))
    (chat-capability--set-verification-fallback session profile)
    (if (chat-verification-profile-steps profile)
        (progn
          (chat-capability--unadvertise-tools
           chat-capability-programming-verification-fallback-tools)
          (chat-capability--advertise-tools
           chat-capability-programming-verification-run-tools))
      (chat-capability--advertise-tools
       chat-capability-programming-verification-fallback-tools))
    (chat-code-verify-profile-to-alist profile)))

(defun chat-capability--verification-context ()
  "Return correlation fields for the current capability session."
  (let* ((session (ignore-errors (chat-capability--current-session)))
         (source
          (and (boundp 'chat-tool-caller-current-execution-context)
               chat-tool-caller-current-execution-context))
         context)
    (dolist (key '(:session-id :turn-id :task-id :run-id :parent-id
                   :checkpoint-id :changed-files :preflight-fingerprints))
      (when (plist-member source key)
        (setq context (plist-put context key (plist-get source key)))))
    (when session
      (setq context
            (plist-put context :session-id (chat-session-id session))))
    context))

(defun chat-capability-programming-verification-run (profile-id)
  "Run cached verification PROFILE-ID synchronously."
  (require 'chat-code-verify)
  (let* ((context (chat-capability--verification-context))
         (profile (chat-code-verify-get-profile profile-id)))
    (unless profile (error "Unknown verification profile: %s" profile-id))
    (unless (chat-code-verify-profile-owned-p
             profile-id (plist-get context :session-id)
             (plist-get context :task-id))
      (error "Verification profile is not owned by the current session task: %s"
             profile-id))
    (let ((result (chat-code-verify-run-sync profile context)))
      (chat-capability--advertise-tools
       chat-capability-programming-verification-result-tools)
      (chat-code-verify-result-data result))))

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
      (if (not (chat-code-verify-profile-owned-p
                profile-id (plist-get context :session-id)
                (plist-get context :task-id)))
          (progn
            (funcall
             error-callback
             (format
              "Verification profile is not owned by the current session task: %s"
              profile-id))
            nil)
        (apply
         #'chat-code-verify-run profile
         (append
          context
          (list :on-complete
                (lambda (result)
                  (chat-capability--advertise-tools
                   chat-capability-programming-verification-result-tools)
                  (funcall success
                           (chat-code-verify-result-data result))))))))))

(defun chat-capability-programming-verification-read-result (verification-id)
  "Read typed verification result VERIFICATION-ID."
  (require 'chat-code-verify)
  (let* ((context (chat-capability--verification-context))
         (result (chat-code-verify-get verification-id)))
    (unless result
      (error "Unknown verification result: %s" verification-id))
    (unless (chat-code-verify-result-owned-p
             result (plist-get context :session-id)
             (plist-get context :task-id))
      (error "Verification result is not owned by the current session task: %s"
             verification-id))
    (chat-code-verify-result-data result)))

(defun chat-capability--work-context-identity ()
  "Return current session and task identity for work-context tools."
  (let* ((session (chat-capability--current-session))
         (context (and (boundp 'chat-tool-caller-current-execution-context)
                       chat-tool-caller-current-execution-context)))
    (list :session-id (chat-session-id session)
          :task-id (plist-get context :task-id)
          :turn-id (plist-get context :turn-id)
          :project-root (chat-session-working-directory session))))

(defun chat-capability-programming-work-note-upsert
    (key kind value-json &optional expected-revision tags-json)
  "Create or update one structured working note."
  (require 'chat-work-context)
  (let* ((identity (chat-capability--work-context-identity))
         (session-id (plist-get identity :session-id))
         (task-id (plist-get identity :task-id))
         (value (json-parse-string value-json :object-type 'alist
                                   :array-type 'list :null-object nil
                                   :false-object :json-false))
         (tags (mapcar #'intern
                       (chat-capability--json-string-list tags-json "tags_json"))))
    (chat-work-note-to-alist
     (chat-work-note-upsert
      session-id key value :expected-revision expected-revision
      :task-id task-id :kind (intern kind) :tags tags
      :scope (if task-id 'task 'session) :scope-id (or task-id session-id)
      :source-kind 'agent
      :source-id (format "turn:%s" (or (plist-get identity :turn-id) "unknown"))))))

(defun chat-capability-programming-work-note-query (&optional kind tag)
  "Query current session working notes by optional KIND and TAG."
  (require 'chat-work-context)
  (let* ((identity (chat-capability--work-context-identity))
         (notes (chat-work-note-list
                 (plist-get identity :session-id)
                 :task-id (plist-get identity :task-id)
                 :kind (and kind (not (string-empty-p kind)) (intern kind))
                 :tag (and tag (not (string-empty-p tag)) (intern tag))
                 :status 'active)))
    (vconcat (mapcar #'chat-work-note-to-alist notes))))

(defun chat-capability-programming-work-note-archive (note-id revision)
  "Archive NOTE-ID at REVISION."
  (require 'chat-work-context)
  (let ((identity (chat-capability--work-context-identity)))
    (chat-work-note-to-alist
     (chat-work-note-set-status
      (plist-get identity :session-id) note-id revision 'archived))))

(defun chat-capability-programming-work-note-resolve (note-id revision)
  "Resolve NOTE-ID at REVISION."
  (require 'chat-work-context)
  (let ((identity (chat-capability--work-context-identity)))
    (chat-work-note-to-alist
     (chat-work-note-resolve
      (plist-get identity :session-id) note-id revision))))

(defun chat-capability-programming-work-note-supersede
    (note-id revision key value-json &optional kind tags-json)
  "Replace NOTE-ID with a distinct note derived from VALUE-JSON."
  (require 'chat-work-context)
  (let* ((identity (chat-capability--work-context-identity))
         (value (json-parse-string value-json :object-type 'alist
                                   :array-type 'list :null-object nil
                                   :false-object :json-false))
         (tags (mapcar #'intern
                       (chat-capability--json-string-list tags-json "tags_json"))))
    (chat-work-note-to-alist
     (chat-work-note-supersede
      (plist-get identity :session-id) note-id revision key value
      :kind (and kind (not (string-empty-p kind)) (intern kind))
      :tags tags :source-kind 'agent
      :source-id (format "turn:%s"
                         (or (plist-get identity :turn-id) "unknown"))))))

(defun chat-capability-programming-work-note-delete (note-id revision)
  "Delete NOTE-ID at REVISION."
  (require 'chat-work-context)
  (let ((identity (chat-capability--work-context-identity)))
    `((id . ,note-id)
      (deleted . ,(chat-work-note-delete
                   (plist-get identity :session-id) note-id revision)))))

(defun chat-capability-programming-context-inspect (&optional target-path)
  "Inspect scoped project instruction sources for TARGET-PATH."
  (require 'chat-project)
  (let* ((identity (chat-capability--work-context-identity))
         (project (or (plist-get identity :project-root) default-directory))
         (candidate (expand-file-name (or target-path project)))
         (target (if (file-regular-p candidate)
                     (file-name-directory candidate)
                   candidate)))
    (unless (chat-work-context--inside-p target project)
      (error "Context target is outside the current project: %s" target))
    (let ((graph (chat-project-instruction-graph target)))
      `((projectRoot . ,(plist-get graph :project-root))
        (sources . ,(vconcat
                      (mapcar
                       (lambda (fragment)
                         `((id . ,(chat-context-fragment-id fragment))
                           (path . ,(chat-context-fragment-source-path fragment))
                           (scope . ,(symbol-name
                                      (chat-context-fragment-scope fragment)))
                           (scopeId . ,(chat-context-fragment-scope-id fragment))
                           (digest . ,(chat-context-fragment-digest fragment))))
                       (plist-get graph :fragments))))
        (diagnostics . ,(vconcat (plist-get graph :diagnostics)))))))

(defun chat-capability--work-plan-session ()
  "Return the current execution session for plan tools."
  (or (chat-capability--current-session)
      (error "A current session is required")))

(defun chat-capability-programming-goal-create
    (objective criteria-json stopping-condition &optional constraints-json
               non-goals-json sources-json)
  "Create a durable Goal contract from structured JSON arguments."
  (let ((criteria (json-parse-string
                   criteria-json :object-type 'alist :array-type 'list
                   :null-object nil :false-object :json-false))
        (constraints (and constraints-json
                          (not (string-empty-p constraints-json))
                          (chat-capability--json-string-list
                           constraints-json "constraints_json")))
        (non-goals (and non-goals-json
                        (not (string-empty-p non-goals-json))
                        (chat-capability--json-string-list
                         non-goals-json "non_goals_json")))
        (sources (and sources-json
                      (not (string-empty-p sources-json))
                      (chat-capability--json-string-list
                       sources-json "sources_json"))))
    (let ((session (chat-capability--work-plan-session)))
      (chat-goal-to-alist
       (chat-goal-create
        session objective criteria stopping-condition
        :constraints constraints :non-goals non-goals :sources sources
        :project-root (chat-session-working-directory session))))))

(defun chat-capability-programming-goal-read (&optional goal-id)
  "Read GOAL-ID or the selected Goal."
  (let* ((session (chat-capability--work-plan-session))
         (goal (if (and goal-id (not (string-empty-p goal-id)))
                   (chat-goal-find session goal-id)
                 (chat-goal-current session))))
    (if goal (chat-goal-to-alist goal)
      (error "Goal not found"))))

(defun chat-capability-programming-goal-list ()
  "List bounded durable Goal history for the current session."
  (vconcat
   (mapcar #'chat-goal-to-alist
           (chat-goal-list (chat-capability--work-plan-session)))))

(defun chat-capability-programming-goal-progress
    (goal-id revision &optional checkpoint message criterion-id evidence
             plan-id task-id)
  "Record Goal progress using an observed REVISION."
  (let ((evidence (chat-capability--string-list evidence "evidence")))
    (chat-goal-to-alist
     (chat-goal-progress
      (chat-capability--work-plan-session) goal-id revision
      :checkpoint checkpoint :message message :criterion-id criterion-id
      :evidence evidence :plan-id plan-id :task-id task-id))))

(defun chat-capability-programming-goal-block
    (goal-id revision reason unblock-condition)
  "Block a Goal with an actionable reason and unblock condition."
  (chat-goal-to-alist
   (chat-goal-block (chat-capability--work-plan-session)
                    goal-id revision reason unblock-condition)))

(defun chat-capability-programming-goal-complete (goal-id revision)
  "Complete a Goal only after deterministic evidence verification."
  (chat-goal-to-alist
   (chat-goal-complete
    (chat-capability--work-plan-session) goal-id revision)))

(defun chat-capability-programming-plan-create (objective items &optional mode)
  "Create a durable plan and, outside Plan Mode, start its first item."
  (let* ((items (chat-capability--work-plan-items items "items"))
         (session (chat-capability--work-plan-session))
         (plan
         (chat-work-plan-create
           session objective items
           :mode (and mode (not (string-empty-p mode)) (intern mode)))))
    (chat-capability--advertise-tools
     chat-capability-programming-plan-tools)
    ;; The lifecycle group includes create for pre-plan activation.  Once this
    ;; plan exists, keep only the operations that can read, advance, or close it.
    (chat-capability--unadvertise-tools '(programming_plan_create))
    (unless (chat-plan-mode-active-p session)
      (setq plan
            (chat-work-plan-start-first-ready
             session (chat-work-plan-id plan) (chat-work-plan-revision plan)))
      (chat-capability--advertise-tools
       (chat-capability--ordered-tool-union
        chat-capability-programming-execution-tools
        chat-capability-programming-verification-plan-tools)))
    (chat-work-plan-to-alist plan)))

(defun chat-capability-programming-plan-read (&optional plan-id)
  "Read PLAN-ID or the selected work plan."
  (let* ((session (chat-capability--work-plan-session))
         (plan (if (and plan-id (not (string-empty-p plan-id)))
                   (chat-work-plan-find session plan-id)
                 (chat-work-plan-current session t))))
    (if plan (chat-work-plan-to-alist plan)
      (error "Work plan not found"))))

(defun chat-capability-programming-plan-list ()
  "List bounded durable plans for the current session."
  (vconcat
   (mapcar #'chat-work-plan-to-alist
           (chat-work-plan-list (chat-capability--work-plan-session)))))

(defun chat-capability-programming-plan-update
    (plan-id revision items &optional objective)
  "Replace a plan's unstarted future ITEMS."
  (let ((items (chat-capability--work-plan-items items "items")))
    (chat-work-plan-to-alist
     (chat-work-plan-update-future
      (chat-capability--work-plan-session) plan-id revision items
      :objective objective))))

(defun chat-capability-programming-plan-submit (plan-id planning-revision)
  "Submit PLAN-ID for explicit user approval."
  (chat-plan-mode-to-alist
   (chat-plan-mode-submit
    (chat-capability--work-plan-session) plan-id planning-revision)))

(defun chat-capability-programming-plan-mode-enter ()
  "Enter read-only Plan Mode for the current execution session."
  (chat-plan-mode-to-alist
   (chat-plan-mode-enter (chat-capability--work-plan-session))))

(defun chat-capability-programming-plan-transition
    (plan-id revision item-id status &optional evidence blocker-reason)
  "Transition one plan item with optional EVIDENCE ids."
  (let ((evidence (chat-capability--string-list evidence "evidence")))
    (chat-work-plan-to-alist
     (chat-work-plan-transition-item
      (chat-capability--work-plan-session) plan-id revision item-id
      (intern status) :evidence evidence :blocker-reason blocker-reason))))

(defun chat-capability-programming-plan-resume (plan-id revision)
  "Resume a blocked plan."
  (chat-work-plan-to-alist
   (chat-work-plan-resume
    (chat-capability--work-plan-session) plan-id revision)))

(defun chat-capability-programming-plan-cancel (plan-id revision)
  "Cancel an active or blocked plan."
  (chat-work-plan-to-alist
   (chat-work-plan-cancel
    (chat-capability--work-plan-session) plan-id revision)))

(defun chat-capability-programming-plan-skip
    (reason &optional tool-name action-facts-json)
  "Record one audited simple-task plan skip."
  (let ((facts (and action-facts-json
                    (not (string-empty-p action-facts-json))
                    (json-parse-string action-facts-json :object-type 'alist
                                       :array-type 'list :null-object nil
                                       :false-object :json-false))))
    (chat-work-plan-to-alist
     (chat-work-plan-skip
      (chat-capability--work-plan-session) (intern reason)
      :tool-name tool-name :action-facts facts))))

(defun chat-capability-programming-plan-mode (&optional mode)
  "Read or set the current session plan MODE."
  (let ((session (chat-capability--work-plan-session)))
    (when (and mode (not (string-empty-p mode)))
      (chat-work-plan-set-mode session (intern mode)))
    `((mode . ,(symbol-name
                (chat-work-plan-enforcement-mode session))))))

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
   'programming_capability_activate "Programming Capability Activate"
   (concat "Expose a stage tool group for this run. programming_plan_create is "
           "already visible and starts the first item for ordinary coding; "
           "activate plan only for read-only Plan Mode or lifecycle operations "
           "before a plan exists. Use exploration for editor semantics or web "
           "lookup, and goal only when explicitly requested. Ordinary plan "
           "creation exposes all file mutation and compile tools.")
   '((:name "capability" :type "string" :required t
      :enum ("exploration" "plan" "goal" "notes" "verification"
             "context")))
   #'chat-capability-programming-capability-activate 'project '(state))
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
   'programming_review_diff "Programming Review Diff"
   "Read a bounded project diff from an explicit base revision."
   '((:name "project_root" :type "string" :required t)
     (:name "base_revision" :type "string" :required nil))
   #'chat-capability-programming-review-diff 'project '(read))
  (chat-capability--register-tool
   'programming_review_repo_map "Programming Review Repo Map"
   "Read ranked repository-map evidence without mutating the project."
   '((:name "project_root" :type "string" :required t)
     (:name "query" :type "string" :required t)
     (:name "changed_files" :type "array" :required nil
      :description "Changed project-relative file paths."
      :items ((type . "string"))))
   #'chat-capability-programming-review-repo-map 'project '(read))
  (chat-capability--register-tool
   'programming_compile_task "Programming Compile Task"
   (concat "Start one exact compile or test command as a background task. "
           "Prefer Programming Verification Plan and Run for detected project "
           "checks. Execution uses an isolated temporary HOME/TMPDIR; do not "
           "relocate or clean generated caches unless they are tracked or the "
           "user requested cleanup.")
   '((:name "command" :type "string" :required t)
     (:name "directory" :type "string" :required nil))
   #'chat-capability-programming-compile-task 'project '(write outbound))
  (chat-capability--register-tool
   'programming_task_output "Programming Task Output"
   (concat "Read structured status and bounded output from a compile or test "
           "task started in this session. Empty output is not evidence that "
           "the task is still running: inspect terminal, status and exitCode. "
           "Do not rerun a command merely because output is empty. Continue "
           "from nextOffset when truncated.")
   '((:name "id" :type "string" :required t)
     (:name "offset" :type "integer" :required nil)
     (:name "max_bytes" :type "integer" :required nil))
   #'chat-capability-programming-task-output 'project '(read))
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
   (concat "Resolve deterministic, language-aware project checks without "
           "executing them. Use this after code edits before inventing a shell "
           "command. Pass changed file paths as the native changed_files array. "
           "The returned id is a verification profile id: pass it "
           "only to programming_verification_run, never to "
           "programming_verification_read_result.")
   '((:name "project_root" :type "string" :required t)
     (:name "changed_files" :type "array" :required nil
      :description "Changed project-relative file paths."
      :items ((type . "string"))))
   #'chat-capability-programming-verification-plan 'project '(read))
  (chat-capability--register-tool
   'programming_verification_run "Programming Verification Run"
   (concat "Run an existing language-aware verification plan with bounded "
           "output, timeout, isolated caches and structured evidence. Pass "
           "the profile id returned by programming_verification_plan. The "
           "completed run returns a distinct verification id for "
           "programming_verification_read_result.")
   '((:name "profile_id" :type "string" :required t))
   #'chat-capability-programming-verification-run 'project '(read)
   #'chat-capability-programming-verification-run-async)
  (chat-capability--register-tool
   'programming_verification_read_result "Programming Verification Result"
   (concat "Read structured evidence for a completed verification run. Pass "
           "the verification id returned by programming_verification_run; a "
           "verification profile id from programming_verification_plan is "
           "invalid here.")
   '((:name "verification_id" :type "string" :required t))
   #'chat-capability-programming-verification-read-result 'project '(read))
  (chat-capability--register-tool
   'programming_work_note_upsert "Programming Work Note Upsert"
   "Create or revision-update a scoped structured note for the current work."
   '((:name "key" :type "string" :required t)
     (:name "kind" :type "string" :required t
            :enum ("fact" "decision" "constraint" "hypothesis" "artifact"
                   "blocker" "next-step" "note"))
     (:name "value_json" :type "string" :required t)
     (:name "expected_revision" :type "integer" :required nil)
     (:name "tags_json" :type "string" :required nil))
   #'chat-capability-programming-work-note-upsert 'project '(state))
  (chat-capability--register-tool
   'programming_work_note_query "Programming Work Note Query"
   "Query active structured notes for the current task."
   '((:name "kind" :type "string" :required nil)
     (:name "tag" :type "string" :required nil))
   #'chat-capability-programming-work-note-query 'project '(read))
  (chat-capability--register-tool
   'programming_work_note_resolve "Programming Work Note Resolve"
   "Resolve a current work note using its observed revision."
   '((:name "note_id" :type "string" :required t)
     (:name "revision" :type "integer" :required t))
   #'chat-capability-programming-work-note-resolve 'project '(state))
  (chat-capability--register-tool
   'programming_work_note_supersede "Programming Work Note Supersede"
   "Supersede a work note with a distinct revisioned replacement."
   '((:name "note_id" :type "string" :required t)
     (:name "revision" :type "integer" :required t)
     (:name "key" :type "string" :required t)
     (:name "value_json" :type "string" :required t)
     (:name "kind" :type "string" :required nil
            :enum ("fact" "decision" "constraint" "hypothesis" "artifact"
                   "blocker" "next-step" "note"))
     (:name "tags_json" :type "string" :required nil))
   #'chat-capability-programming-work-note-supersede 'project '(state))
  (chat-capability--register-tool
   'programming_work_note_archive "Programming Work Note Archive"
   "Archive a current work note using its observed revision."
   '((:name "note_id" :type "string" :required t)
     (:name "revision" :type "integer" :required t))
   #'chat-capability-programming-work-note-archive 'project '(state))
  (chat-capability--register-tool
   'programming_work_note_delete "Programming Work Note Delete"
   "Delete a current work note using its observed revision."
   '((:name "note_id" :type "string" :required t)
     (:name "revision" :type "integer" :required t))
   #'chat-capability-programming-work-note-delete 'project '(state))
  (chat-capability--register-tool
   'programming_context_inspect "Programming Context Inspect"
   "Inspect scoped project instruction sources and dependency diagnostics."
   '((:name "target_path" :type "string" :required nil))
   #'chat-capability-programming-context-inspect 'project '(read))
  (chat-capability--register-tool
   'programming_goal_create "Programming Goal Create"
   "Create one durable cross-turn Goal contract. A Goal requires explicit success criteria and a verifiable stopping condition; it is not a TODO list."
   '((:name "objective" :type "string" :required t)
     (:name "criteria_json" :type "string" :required t)
     (:name "stopping_condition" :type "string" :required t)
     (:name "constraints_json" :type "string" :required nil)
     (:name "non_goals_json" :type "string" :required nil)
     (:name "sources_json" :type "string" :required nil))
   #'chat-capability-programming-goal-create 'project '(state))
  (chat-capability--register-tool
   'programming_goal_read "Programming Goal Read"
   "Read the selected durable Goal or one known Goal id."
   '((:name "goal_id" :type "string" :required nil))
   #'chat-capability-programming-goal-read 'project '(read))
  (chat-capability--register-tool
   'programming_goal_list "Programming Goal List"
   "List bounded durable Goal history for the current session."
   nil #'chat-capability-programming-goal-list 'project '(read))
  (chat-capability--register-tool
   'programming_goal_progress "Programming Goal Progress"
   "Record a checkpoint, known evidence, a satisfied criterion, or plan/task links using the observed Goal revision. This cannot change the Goal contract."
   '((:name "goal_id" :type "string" :required t)
     (:name "revision" :type "integer" :required t)
     (:name "checkpoint" :type "string" :required nil)
     (:name "message" :type "string" :required nil)
     (:name "criterion_id" :type "string" :required nil)
     (:name "evidence" :type "array" :required nil
      :description "Exact Evidence IDs returned by successful tools."
      :items ((type . "string")) :accepted-types ("string"))
     (:name "plan_id" :type "string" :required nil)
     (:name "task_id" :type "string" :required nil))
   #'chat-capability-programming-goal-progress 'project '(state))
  (chat-capability--register-tool
   'programming_goal_block "Programming Goal Block"
   "Block an active Goal only for a real external or user-action dependency, with an actionable unblock condition."
   '((:name "goal_id" :type "string" :required t)
     (:name "revision" :type "integer" :required t)
     (:name "reason" :type "string" :required t)
     (:name "unblock_condition" :type "string" :required t))
   #'chat-capability-programming-goal-block 'project '(state))
  (chat-capability--register-tool
   'programming_goal_complete "Programming Goal Complete"
   "Request deterministic Goal completion. The call fails unless every required criterion has known scoped evidence and the stopping predicate passes."
   '((:name "goal_id" :type "string" :required t)
     (:name "revision" :type "integer" :required t))
   #'chat-capability-programming-goal-complete 'project '(state))
  (chat-capability--register-tool
   'programming_plan_mode_enter "Programming Plan Mode Enter"
   "Enter read-only Plan Mode only when the user explicitly requests planning without implementation. Never call this as a prerequisite for programming_plan_create; ordinary coding uses a durable work plan without Plan Mode. This tool cannot approve, reject, cancel, or leave Plan Mode."
   nil #'chat-capability-programming-plan-mode-enter 'project '(state))
  (chat-capability--register-tool
   'programming_plan_create "Programming Plan Create"
   (concat "Create the durable TODO plan for substantial coding. In ordinary "
           "coding the first dependency-ready item starts atomically; do not issue "
           "a separate start transition. In read-only Plan Mode items remain "
           "pending for user approval. TODO items are control points, not a transcript: "
           "use the fewest items that preserve real dependencies, approvals, and "
           "distinct acceptance outcomes. Combine related edits and their "
           "verification when one observable result closes both. Each item needs "
           "a concrete title and observable acceptance evidence.")
   `((:name "objective" :type "string" :required t
      :description "The bounded outcome this work plan must achieve.")
     (:name "items" :type "array" :required t :min-items 1
      :description "Ordered implementation steps with acceptance evidence."
      :items ,chat-capability--work-plan-item-schema)
     (:name "mode" :type "string" :required nil
      :description "Plan enforcement for this work."
      :enum ("auto" "required" "off")))
   #'chat-capability-programming-plan-create 'project '(state))
  (chat-capability--register-tool
   'programming_plan_read "Programming Plan Read"
   "Read the selected durable plan or one known plan id."
   '((:name "plan_id" :type "string" :required nil))
   #'chat-capability-programming-plan-read 'project '(read))
  (chat-capability--register-tool
   'programming_plan_list "Programming Plan List"
   "List the bounded durable plan history for the current session."
   nil #'chat-capability-programming-plan-list 'project '(read))
  (chat-capability--register-tool
   'programming_plan_update "Programming Plan Update"
   "Replace only the unstarted future tail of a plan using the observed revision. Started and terminal items remain immutable."
   `((:name "plan_id" :type "string" :required t)
     (:name "revision" :type "integer" :required t)
     (:name "items" :type "array" :required t :min-items 1
      :description "Replacement future steps with acceptance evidence."
      :items ,chat-capability--work-plan-item-schema)
     (:name "objective" :type "string" :required nil))
   #'chat-capability-programming-plan-update 'project '(state))
  (chat-capability--register-tool
   'programming_plan_submit "Programming Plan Submit"
   "Submit a complete pending plan for user approval while Plan Mode remains read-only. This tool cannot approve the plan."
   '((:name "plan_id" :type "string" :required t)
     (:name "planning_revision" :type "integer" :required t))
   #'chat-capability-programming-plan-submit 'project '(state))
  (chat-capability--register-tool
   'programming_plan_transition "Programming Plan Transition"
   (concat "Start, complete, block, or skip one plan item using the observed "
           "revision. The first item is already active after ordinary plan "
           "creation; complete only that active item, then start the next pending "
           "item. Completion requires known evidence ids. Transitions are "
           "serial: wait for each result and use its returned revision before "
           "requesting the next transition.")
   '((:name "plan_id" :type "string" :required t)
     (:name "revision" :type "integer" :required t)
     (:name "item_id" :type "string" :required t)
     (:name "status" :type "string" :required t
      :enum ("in-progress" "completed" "blocked" "skipped"))
     (:name "evidence" :type "array" :required nil
      :description "Exact Evidence IDs returned by successful tools. Required when completing an item."
      :items ((type . "string")) :accepted-types ("string"))
     (:name "blocker_reason" :type "string" :required nil))
   #'chat-capability-programming-plan-transition 'project '(state))
  (chat-capability--register-tool
   'programming_plan_resume "Programming Plan Resume"
   "Explicitly resume a blocked or interrupted plan."
   '((:name "plan_id" :type "string" :required t)
     (:name "revision" :type "integer" :required t))
   #'chat-capability-programming-plan-resume 'project '(state))
  (chat-capability--register-tool
   'programming_plan_cancel "Programming Plan Cancel"
   "Cancel a durable plan using the observed revision."
   '((:name "plan_id" :type "string" :required t)
     (:name "revision" :type "integer" :required t))
   #'chat-capability-programming-plan-cancel 'project '(state))
  (chat-capability--register-tool
   'programming_plan_skip "Programming Plan Skip"
   "Audit an allowed simple-task skip. A single bounded mutation must name files_write, files_replace, or files_patch."
   '((:name "reason" :type "string" :required t
      :enum ("answer-only" "read-only" "single-bounded-action"))
     (:name "tool_name" :type "string" :required nil)
     (:name "action_facts_json" :type "string" :required nil))
   #'chat-capability-programming-plan-skip 'project '(state))
  (chat-capability--register-tool
   'programming_plan_mode "Programming Plan Mode"
   "Read or explicitly set auto, required, or off plan enforcement."
   '((:name "mode" :type "string" :required nil
      :enum ("auto" "required" "off")))
   #'chat-capability-programming-plan-mode 'project '(write))
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
