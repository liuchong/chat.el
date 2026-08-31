;;; test-chat-capability-packs.el --- Tests for capability packs -*- lexical-binding: t -*-

(require 'ert)
(require 'test-helper)
(require 'chat-capability-packs)

(ert-deftest chat-capability-profile-applies-session-tool-overlay ()
  "Test capability profiles scope visible tools through session config."
  (let ((session (make-chat-session :id "profile")))
    (chat-capability-apply-profile session 'daily)
    (should (chat-session-tool-enabled-p session 'daily_calendar_today))
    (should (chat-session-tool-enabled-p session 'web_eww_read))
    (should-not (chat-session-tool-enabled-p session 'programming_git_status))
    (should (eq (plist-get (chat-session-tool-config session) :profile)
                'daily))))

(ert-deftest chat-capability-all-profile-keeps-tools-unrestricted ()
  "The all profile omits the allowlist instead of declaring an empty one."
  (let ((session (make-chat-session :id "all-profile")))
    (chat-capability-apply-profile session 'all)
    (should-not (plist-member (chat-session-tool-config session)
                              :enabled-tools))
    (should (chat-session-tool-enabled-p session 'any-tool))))

(ert-deftest chat-capability-code-profile-stages-its-provider-tool-menu ()
  "The code profile keeps full authority while advertising a small base menu."
  (let* ((profile (chat-agent-profile-resolve 'code))
         (session (make-chat-session :id "staged-code"))
         (config (chat-agent-profile--effective-tool-config session profile)))
    (should (equal chat-capability-programming-tools
                   (plist-get config :enabled-tools)))
    (dolist (tool chat-capability-programming-execution-tools)
      (should (memq tool (plist-get config :enabled-tools))))
    (dolist (tool chat-capability-programming-verification-fallback-tools)
      (should (memq tool (plist-get config :enabled-tools))))
    (should (equal chat-capability-programming-base-tools
                   (plist-get config :advertised-tools)))
    (should (memq 'programming_plan_create
                  (plist-get config :advertised-tools)))
    (dolist (tool chat-capability-programming-execution-tools)
      (should-not (memq tool (plist-get config :advertised-tools))))
    (dolist (tool chat-capability-programming-verification-fallback-tools)
      (should-not (memq tool (plist-get config :advertised-tools))))
    (should-not (memq 'programming_plan_transition
                      (plist-get config :advertised-tools)))))

(ert-deftest chat-capability-activation-expands-only-the-execution-menu ()
  "Activating a group preserves authority and the durable state session."
  (let* ((chat-tool-forge--registry (make-hash-table :test 'eq))
         (execution (make-chat-session :id "activation-execution"))
         (state (make-chat-session :id "activation-state"))
         (chat-tool-caller-current-session execution)
         (chat-tool-caller-current-state-session state))
    (chat-capability-register-tools)
    (chat-session-set-tool-config
     execution
     (list :enabled-tools chat-capability-programming-tools
           :advertised-tools chat-capability-programming-base-tools))
    (let ((names
           (mapcar (lambda (definition)
                     (alist-get 'name (alist-get 'function definition)))
                   (append (chat-tool-caller-provider-tools) nil))))
      (should (member "programming_plan_create" names))
      (should-not (member "programming_plan_transition" names)))
    (chat-capability-programming-capability-activate "plan")
    (should (memq 'programming_plan_create
                  (plist-get (chat-session-tool-config execution)
                             :advertised-tools)))
    (should
     (member "programming_plan_create"
             (mapcar (lambda (definition)
                       (alist-get 'name (alist-get 'function definition)))
                     (append (chat-tool-caller-provider-tools) nil))))
    (should-not (chat-session-tool-config state))))

(ert-deftest chat-capability-batch-edit-follows-the-work-plan-stage ()
  "Structured batch editing cannot bypass the ordinary Plan gate."
  (let* ((execution (make-chat-session :id "batch-edit-execution"))
         (chat-tool-caller-current-session execution)
         (chat-tool-caller-current-state-session execution))
    (chat-session-set-tool-config
     execution
     (list :enabled-tools chat-capability-programming-tools
           :advertised-tools chat-capability-programming-base-tools))
    (should (memq 'files_patch chat-capability-programming-execution-tools))
    (should-not (memq 'files_patch
                      (plist-get (chat-session-tool-config execution)
                                 :advertised-tools)))
    (should-error
     (chat-capability-programming-capability-activate "batch-edit"))
    (should-not (memq 'files_patch
                      (plist-get (chat-session-tool-config execution)
                                 :advertised-tools)))
    (chat-capability-programming-plan-create
     "Batch edit"
     '(((id . "edit") (title . "Apply structured edits")
        (acceptance . "The intended replacements are present."))))
    (should-not
     (memq 'programming_plan_create
           (plist-get (chat-session-tool-config execution)
                      :advertised-tools)))
    (should (memq 'programming_plan_transition
                  (plist-get (chat-session-tool-config execution)
                             :advertised-tools)))
    (should (memq 'files_patch
                  (plist-get (chat-session-tool-config execution)
                             :advertised-tools)))))

(ert-deftest chat-capability-verification-context-excludes-agent-private-state ()
  "Verification receives correlation facts but not the Agent's read set."
  (let* ((session (make-chat-session :id "verification-context"))
         (chat-tool-caller-current-state-session session)
         (chat-tool-caller-current-execution-context
          (list :session-id "stale" :turn-id 4 :task-id "task-4"
                :run-id "run-4" :read-set (make-hash-table :test 'equal)
                :allowed-paths '("sample.js")))
         (context (chat-capability--verification-context)))
    (should (equal "verification-context" (plist-get context :session-id)))
    (should (= 4 (plist-get context :turn-id)))
    (should (equal "task-4" (plist-get context :task-id)))
    (should (equal "run-4" (plist-get context :run-id)))
    (should-not (plist-member context :read-set))
    (should-not (plist-member context :allowed-paths))))

(ert-deftest chat-capability-exploration-is-explicitly-staged ()
  "Editor-semantic and web tools stay available without taxing turn one."
  (let* ((execution (make-chat-session :id "exploration-execution"))
         (chat-tool-caller-current-session execution))
    (chat-session-set-tool-config
     execution
     (list :enabled-tools chat-capability-programming-tools
           :advertised-tools chat-capability-programming-base-tools))
    (dolist (tool chat-capability-programming-exploration-tools)
      (should (memq tool chat-capability-programming-tools))
      (should-not (memq tool
                        (plist-get (chat-session-tool-config execution)
                                   :advertised-tools))))
    (chat-capability-programming-capability-activate "exploration")
    (dolist (tool chat-capability-programming-exploration-tools)
      (should (memq tool
                    (plist-get (chat-session-tool-config execution)
                               :advertised-tools))))))

(ert-deftest chat-capability-active-plan-is-advertised-on-the-next-run ()
  "A durable plan restores its lifecycle tools without another activation call."
  (chat-test-with-temp-dir
   (let* ((session (make-chat-session :id "active-plan-menu"))
          (profile (chat-agent-profile-resolve 'code)))
     (chat-session-set-working-directory session temp-dir)
     (chat-work-plan-create
      session "Plan"
      '(((id . "step") (title . "Implement") (acceptance . "Tests pass"))))
     (let ((config (chat-agent-profile--effective-tool-config session profile)))
       (should (memq 'programming_plan_transition
                     (plist-get config :advertised-tools)))))))

(ert-deftest chat-capability-office-tools-read_and_mutate_allowed_roots ()
  "Test office tools read Org headings and mutate allowed directories."
  (chat-test-with-temp-dir
   (let* ((chat-files-allowed-directories (list temp-dir))
          (org-file (expand-file-name "notes.org" temp-dir))
          (dir (expand-file-name "folder" temp-dir))
          (renamed (expand-file-name "renamed" temp-dir)))
     (with-temp-file org-file
       (insert "* Inbox\n** Follow up\n"))
     (should (equal (mapcar (lambda (headline)
                              (cdr (assoc 'title headline)))
                            (chat-capability-office-org-headlines org-file))
                    '("Inbox" "Follow up")))
     (chat-capability-office-dired-mkdir dir)
     (should (file-directory-p dir))
     (chat-capability-office-dired-rename dir renamed)
     (should (file-directory-p renamed))
     (let* ((source (expand-file-name "source.txt" temp-dir))
            (target (expand-file-name "target.txt" temp-dir)))
       (with-temp-file source (insert "copy me"))
       (chat-capability-office-dired-copy source target)
       (should (file-exists-p target))
       (should (get-buffer
                (cdr (assoc 'buffer
                            (chat-capability-office-dired-open target))))))
     (should (string= (chat-capability-office-calc-eval "2+3") "5"))
     (should (string-match-p
              "100"
              (chat-capability-office-calc-convert "1 m" "cm"))))))

(ert-deftest chat-capability-programming-capf-uses-file-major-mode ()
  "Test programming completion delegates to native CAPF sources."
  (chat-test-with-temp-dir
   (let* ((chat-files-allowed-directories (list temp-dir))
          (path (expand-file-name "sample.el" temp-dir)))
     (with-temp-file path
       (insert "(mes"))
     (let* ((result
             (chat-capability-programming-completion-at-point
              path 1 4 50))
            (candidates (cdr (assoc 'candidates result))))
       (should (equal (cdr (assoc 'prefix result)) "mes"))
       (should (seq-some
                (lambda (candidate)
                  (string-prefix-p "message" candidate))
                candidates))))))

(ert-deftest chat-capability-compile-task-defaults-to-session-project ()
  "An omitted directory cannot make verification drift into the host process cwd."
  (chat-test-with-temp-dir
   (let* ((session (make-chat-session :id "compile-session"))
          (chat-tool-caller-current-state-session session)
          (default-directory "/")
          captured)
     (chat-session-set-working-directory session temp-dir)
     (cl-letf (((symbol-function 'chat-work-task-start)
                (lambda (command directory)
                  (setq captured (cons command directory))
                  'started)))
       (should (eq (chat-capability-programming-compile-task "make test")
                   'started))
       (should (equal captured
                      (cons "make test" (file-name-as-directory temp-dir))))))))

(ert-deftest chat-capability-programming-profile-exposes-task-output ()
  "The code profile can inspect the result of its own compile task."
  (let ((chat-tool-forge--registry (make-hash-table :test 'eq)))
    (chat-capability-register-tools)
    (should (memq 'programming_task_output
                  chat-capability-programming-tools))
    (let ((tool (chat-tool-forge-get 'programming_task_output)))
      (should tool)
      (should (equal (chat-forged-tool-effects tool) '(read))))))

(ert-deftest chat-capability-web-reader-renders-html-with-shr ()
  "Test the shared web tool returns rendered page text."
  (cl-letf (((symbol-function 'url-retrieve-synchronously)
             (lambda (&rest _args)
               (let ((buffer (generate-new-buffer " *capability-web*")))
                 (with-current-buffer buffer
                   (insert "HTTP/1.1 200 OK\r\n\r\n")
                   (insert "<html><body><h1>Hello</h1><p>World</p></body></html>"))
                 buffer))))
    (let ((result
           (chat-capability-web-eww-read
            "https://example.invalid/page")))
      (should (string-match-p "Hello"
                              (cdr (assoc 'content result))))
      (should (string-match-p "World"
                              (cdr (assoc 'content result)))))))

(ert-deftest chat-capability-web-reader-has-nonblocking-tool-path ()
  "Test web reads expose an asynchronous cancellable execution path."
  (let ((chat-tool-forge--registry (make-hash-table :test 'eq))
        result)
    (chat-capability-register-tools)
    (cl-letf (((symbol-function 'url-retrieve)
               (lambda (_url callback &rest _args)
                 (let ((buffer (generate-new-buffer
                                " *capability-web-async*")))
                   (with-current-buffer buffer
                     (insert "HTTP/1.1 200 OK\r\n\r\n")
                     (insert "<html><body>Async page</body></html>")
                     (funcall callback nil))
                   buffer))))
      (funcall
       (chat-forged-tool-async-function
        (chat-tool-forge-get 'web_eww_read))
       '("https://example.invalid/async" 1000)
       (lambda (value) (setq result value))
       #'ert-fail))
    (should (string-match-p
             "Async[[:space:]]+page"
             (cdr (assoc 'content result))))))

(ert-deftest chat-capability-office-org-workflow-captures-and-updates ()
  "Test Org agenda, capture, TODO update, and scheduling."
  (chat-test-with-temp-dir
   (let* ((chat-files-allowed-directories (list temp-dir))
          (org-file (expand-file-name "work.org" temp-dir)))
     (with-temp-file org-file
       (insert "* TODO Existing\n"))
     (chat-capability-office-org-capture
      org-file "New item" "Details" "TODO")
     (chat-capability-office-org-todo-update
      org-file "Existing" "DONE")
     (chat-capability-office-org-schedule
      org-file "New item" "2026-08-25")
     (let ((agenda
            (chat-capability-office-org-agenda
             (json-encode (vector org-file)) "2026-08-25")))
       (should (= (length agenda) 1))
       (should (equal (cdr (assoc 'title (car agenda)))
                      "New item")))
     (with-temp-buffer
       (insert-file-contents org-file)
       (should (search-forward "* DONE Existing" nil t))
       (should (search-forward "SCHEDULED: <2026-08-25" nil t))))))

(ert-deftest chat-capability-daily-tools_keep_mail_as_drafts ()
  "Test daily tools support diary and unsent mail drafts."
  (chat-test-with-temp-dir
   (let* ((chat-files-allowed-directories (list temp-dir))
          (chat-capability-mail-drafts nil)
          (diary (expand-file-name "diary" temp-dir)))
     (with-temp-file diary)
     (chat-capability-daily-diary-insert "2026-08-24 Work" diary)
     (should (string-match-p "Work"
                             (chat-capability-daily-diary-read diary)))
     (let ((draft (chat-capability-daily-mail-draft-create
                   "user@example.test" "Hello" "Body")))
       (should (string= (cdr (assoc 'status draft)) "draft"))
       (should (= (length (chat-capability-daily-mail-draft-list)) 1))
       (chat-capability-daily-mail-draft-delete (cdr (assoc 'id draft)))
       (should-not (chat-capability-daily-mail-draft-list)))
     (let* ((draft (chat-capability-daily-message-draft-buffer
                    "user@example.test" "Subject" "Body"))
            (buffer (get-buffer (cdr (assoc 'buffer draft)))))
       (unwind-protect
           (progn
             (should (buffer-live-p buffer))
             (should (eq (buffer-local-value 'major-mode buffer)
                         'message-mode))
             (should (equal (cdr (assoc 'status draft)) "draft")))
         (when (buffer-live-p buffer)
           (kill-buffer buffer)))))))

(ert-deftest chat-capability-register-tools-adds_metadata ()
  "Test capability tools register with owner and permission metadata."
  (let ((chat-tool-forge--registry (make-hash-table :test 'eq)))
    (chat-capability-register-tools)
    (let ((tool (chat-tool-forge-get 'daily_mail_draft_create)))
      (should tool)
      (should (eq (chat-forged-tool-owner tool) 'capability-packs))
      (should (eq (chat-forged-tool-sensitivity tool) 'correspondence))
      (should (memq 'write (chat-forged-tool-effects tool))))
    (dolist (id '(programming_verification_plan
                  programming_verification_run
                  programming_verification_read_result
                  programming_work_note_query
                  programming_context_inspect))
      (let ((tool (chat-tool-forge-get id)))
        (should tool)
        (should (eq (chat-forged-tool-owner tool) 'capability-packs))
        (should (equal (chat-forged-tool-effects tool) '(read)))))))

(ert-deftest chat-capability-work-note-tools-use-current-task-identity ()
  "Work-note tools persist typed values and enforce observed revisions."
  (chat-test-with-temp-dir
   (let* ((chat-work-context-directory (expand-file-name "context/" temp-dir))
          (chat-work-context--stores (make-hash-table :test 'equal))
          (session (make-chat-session :id "capability-context"))
          (chat--current-session session)
          (chat-tool-caller-current-execution-context
           '(:task-id "task-7" :turn-id 3)))
     (chat-session-set-working-directory session temp-dir)
     (let ((created
            (chat-capability-programming-work-note-upsert
             "decision.format" "decision" "{\"choice\":\"native\"}"
             nil "[\"rendering\"]")))
       (should (= (cdr (assoc 'revision created)) 1))
       (should (equal (cdr (assoc 'taskId created)) "task-7"))
       (should (= (length
                   (chat-capability-programming-work-note-query
                    "decision" "rendering"))
                  1))
       (should-error
        (chat-capability-programming-work-note-upsert
         "decision.format" "decision" "{\"choice\":\"stale\"}" nil nil)
        :type 'chat-work-context-stale-revision)
       (let ((updated
              (chat-capability-programming-work-note-upsert
               "decision.format" "decision" "{\"choice\":\"typed\"}" 1 nil)))
         (should (= (cdr (assoc 'revision updated)) 2)))))))

(ert-deftest chat-capability-context-inspect-reports-sources-and-diagnostics ()
  "Context inspection returns bounded identities rather than prompt bodies."
  (chat-test-with-temp-dir
   (let* ((chat-project-global-agents-file
           (expand-file-name "no-global.md" temp-dir))
          (session (make-chat-session :id "inspect"))
          (chat--current-session session))
     (chat-session-set-working-directory session temp-dir)
     (with-temp-file (expand-file-name "AGENTS.md" temp-dir)
       (insert "Scoped rule"))
     (chat-project-cache-clear)
     (let* ((result (chat-capability-programming-context-inspect temp-dir))
            (sources (append (cdr (assoc 'sources result)) nil))
            (source (car sources)))
       (should (= (length sources) 1))
       (should (string-suffix-p "AGENTS.md" (cdr (assoc 'path source))))
       (should (stringp (cdr (assoc 'digest source))))
       (should-not (assoc 'payload source))))))

(ert-deftest chat-capability-profile-filters-provider-tool-schemas ()
  "Test profile overlays control the tools advertised to providers."
  (let ((chat-tool-forge--registry (make-hash-table :test 'eq))
        (session (make-chat-session :id "office-profile")))
    (chat-capability-register-tools)
    (chat-capability-apply-profile session 'office)
    (let* ((chat-tool-caller-current-session session)
           (tools (chat-tool-caller-provider-tools))
           (names
            (mapcar
             (lambda (tool)
               (cdr (assoc 'name
                           (cdr (assoc 'function tool)))))
             (append tools nil))))
      (should (member "office_org_agenda" names))
      (should (member "office_calc_convert" names))
      (should-not (member "programming_completion_at_point" names))
      (should-not (member "daily_message_draft_buffer" names)))))

(ert-deftest chat-capability-state-tools-prefer-the-execution-session ()
  "Async tool state belongs to its explicit session, not the ambient buffer."
  (let ((ambient (make-chat-session :id "ambient"))
        (execution (make-chat-session :id "execution")))
    (let ((chat--current-session ambient)
          (chat-tool-caller-current-session execution)
          (chat-tool-caller-current-state-session execution))
      (chat-capability-programming-plan-create
       "Execution plan"
       '(((id . "step")
          (title . "Run in execution session")
          (acceptance . "Execution session contains the plan.")))))
    (let ((plan (chat-work-plan-current execution)))
      (should (= 2 (chat-work-plan-revision plan)))
      (should (eq 'in-progress
                  (chat-work-plan-item-status
                   (car (chat-work-plan-items plan))))))
    (dolist (tool chat-capability-programming-execution-tools)
      (should (memq tool
                    (plist-get (chat-session-tool-config execution)
                               :advertised-tools))))
    (dolist (tool chat-capability-programming-verification-tools)
      (should (memq tool
                    (plist-get (chat-session-tool-config execution)
                               :advertised-tools))))
    (should-not
     (memq 'programming_compile_task
           (plist-get (chat-session-tool-config execution) :advertised-tools)))
    (dolist (tool chat-capability-programming-plan-tools)
      (unless (eq tool 'programming_plan_create)
        (should (memq tool
                      (plist-get (chat-session-tool-config execution)
                                 :advertised-tools)))))
    (should-not (memq 'programming_plan_create
                      (plist-get (chat-session-tool-config execution)
                                 :advertised-tools)))
    (should-not (chat-work-plan-current ambient))))

(ert-deftest chat-capability-created-plan-transition-is-immediately-callable ()
  "Plan creation exposes the lifecycle operation needed to close the plan."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (chat-tool-forge--registry (make-hash-table :test 'eq))
          (chat-approval-required-effects nil)
          (session (make-chat-session :id "plan-lifecycle-menu"))
          (chat-tool-caller-current-session session)
          (chat-tool-caller-current-state-session session))
     (chat-capability-register-tools)
     (chat-session-set-tool-config
      session
      (list :enabled-tools chat-capability-programming-tools
            :advertised-tools chat-capability-programming-base-tools))
     (let* ((created
             (chat-capability-programming-plan-create
              "Lifecycle"
              '(((id . "step") (title . "Implement")
                 (acceptance . "The dependency is available.")))))
            (plan-id (cdr (assoc 'id created)))
            (revision (cdr (assoc 'revision created)))
            (result
             (chat-tool-caller-execute
              `(:name "programming_plan_transition"
                :arguments
                (("plan_id" . ,plan-id)
                 ("revision" . ,revision)
                 ("item_id" . "step")
                 ("status" . "blocked")
                 ("blocker_reason" . "dependency unavailable")))
              session)))
       (should-not (string-match-p "unavailable for this turn" result))
       (should (eq 'blocked
                   (chat-work-plan-status
                    (chat-work-plan-current session t))))))))

(ert-deftest chat-capability-plan-mode-create-keeps-items-pending ()
  "Read-only Plan Mode never turns proposal creation into execution."
  (let* ((session (make-chat-session :id "planning-only"))
         (chat-tool-caller-current-session session)
         (chat-tool-caller-current-state-session session))
    (chat-plan-mode-enter session)
    (chat-capability-programming-plan-create
     "Proposal"
     '(((id . "step") (title . "Propose")
        (acceptance . "The user can review it."))))
    (let ((plan (chat-work-plan-current session)))
      (should (= 1 (chat-work-plan-revision plan)))
      (should (eq 'pending
                  (chat-work-plan-item-status
                   (car (chat-work-plan-items plan))))))
    (dolist (tool chat-capability-programming-execution-tools)
      (should-not (memq tool
                        (plist-get (chat-session-tool-config session)
                                   :advertised-tools))))))

(ert-deftest chat-capability-active-plan-advertises-execution-tools ()
  "A restored ordinary plan exposes mutation without another activation call."
  (chat-test-with-temp-dir
   (let* ((session (make-chat-session :id "active-plan-execution"))
          (profile (chat-agent-profile-resolve 'code)))
     (chat-session-set-working-directory session temp-dir)
     (let ((plan
            (chat-work-plan-create
             session "Plan"
             '(((id . "step") (title . "Implement")
                (acceptance . "Tests pass"))))))
       (chat-work-plan-start-first-ready
        session (chat-work-plan-id plan) (chat-work-plan-revision plan)))
     (let ((config (chat-agent-profile--effective-tool-config session profile)))
       (should-not (memq 'programming_plan_create
                         (plist-get config :advertised-tools)))
       (should (memq 'programming_plan_transition
                     (plist-get config :advertised-tools)))
       (dolist (tool chat-capability-programming-execution-tools)
         (should (memq tool (plist-get config :advertised-tools))))
       (dolist (tool chat-capability-programming-verification-tools)
         (should (memq tool (plist-get config :advertised-tools))))
       (should-not (memq 'programming_compile_task
                         (plist-get config :advertised-tools)))))))

(ert-deftest chat-capability-generic-compile-requires-an-empty-verification-plan ()
  "Generic commands are a durable fallback, never the first verification path."
  (chat-test-with-temp-dir
   (let* ((session (make-chat-session :id "verification-fallback"))
          (profile (chat-agent-profile-resolve 'code))
          (chat-tool-caller-current-session session)
          (chat-tool-caller-current-state-session session)
          (chat-tool-caller-current-execution-context
           '(:task-id "agent-task")))
     (chat-session-set-working-directory session temp-dir)
     (chat-session-metadata-set session 'activeTaskId "agent-task")
     (let ((plan
            (chat-work-plan-create
             session "Plan"
             '(((id . "step") (title . "Implement")
                (acceptance . "Tests pass"))))))
       (chat-work-plan-start-first-ready
        session (chat-work-plan-id plan) (chat-work-plan-revision plan)))
     (chat-session-set-tool-config
      session
      (chat-agent-profile--effective-tool-config session profile))
     (let ((planned
            (chat-capability-programming-verification-plan temp-dir nil)))
       (should-not (cdr (assoc 'steps planned))))
     (should
      (memq 'programming_compile_task
            (plist-get
             (chat-agent-profile--effective-tool-config session profile)
             :advertised-tools)))
     (let ((chat-tool-caller-current-execution-context
            '(:task-id "other-agent-task")))
       (should-not
        (memq 'programming_compile_task
              (plist-get
               (chat-agent-profile--effective-tool-config session profile)
               :advertised-tools))))
     (let ((plan (chat-work-plan-current session)))
       (chat-work-plan-cancel
        session (chat-work-plan-id plan) (chat-work-plan-revision plan)))
     (should-not
      (memq 'programming_compile_task
            (plist-get
             (chat-agent-profile--effective-tool-config session profile)
             :advertised-tools)))
     (let ((plan
            (chat-work-plan-create
             session "Replacement plan"
             '(((id . "replacement") (title . "Implement replacement")
                (acceptance . "Tests pass"))))))
       (chat-work-plan-start-first-ready
        session (chat-work-plan-id plan) (chat-work-plan-revision plan)))
     (with-temp-file (expand-file-name ".chat-verification.json" temp-dir)
       (insert
        "{\"id\":\"fixture\",\"steps\":[{\"id\":\"test\","
        "\"kind\":\"test\",\"argv\":[\"sh\",\"test-one\",\"active\"],"
        "\"required\":true}]}"))
     (let ((planned
            (chat-capability-programming-verification-plan temp-dir nil)))
       (should (cdr (assoc 'steps planned))))
     (should-not
      (memq 'programming_compile_task
            (plist-get
             (chat-agent-profile--effective-tool-config session profile)
             :advertised-tools))))))

(ert-deftest chat-capability-bounded-skip-transitions-its-tool-menu ()
  "A bounded skip exposes one exact edit, then verification and plan upgrade."
  (chat-test-with-temp-dir
   (let* ((session (make-chat-session :id "bounded-skip-menu"))
          (profile (chat-agent-profile-resolve 'code)))
     (chat-session-set-working-directory session temp-dir)
     (chat-work-plan-skip session 'single-bounded-action
                          :tool-name "files_patch"
                          :task-id "task-1"
                          :action-facts '((path . "sample.el")))
     (chat-session-metadata-set session 'activeTaskId "task-1")
     (chat-session-metadata-set session 'code-enabled t)
     (let ((advertised
            (plist-get
             (chat-agent-profile--effective-tool-config session profile)
             :advertised-tools)))
       (should (memq 'programming_plan_create advertised))
       (should (memq 'programming_plan_read advertised))
       (should (memq 'programming_plan_list advertised))
       (should (memq 'files_patch advertised))
       (dolist (tool '(programming_capability_activate
                       programming_plan_transition programming_plan_skip
                       files_write files_replace apply_patch
                       programming_compile_task
                       programming_verification_run))
         (should-not (memq tool advertised))))
     (should-not
      (chat-work-plan-check-call
       session '(:name "files_patch" :arguments nil)))
     (let ((advertised
            (plist-get
             (chat-agent-profile--effective-tool-config session profile)
             :advertised-tools)))
       (should (memq 'programming_plan_create advertised))
       (should-not (memq 'programming_compile_task advertised))
       (dolist (tool chat-capability-programming-verification-tools)
         (should (memq tool advertised)))
       (dolist (tool '(programming_capability_activate
                       programming_plan_transition programming_plan_skip
                       files_write files_replace files_patch apply_patch))
         (should-not (memq tool advertised)))))))

(ert-deftest chat-capability-bounded-skip-refresh-replaces-stale-runtime-menu ()
  "Each step replaces stale activations with the bounded-skip stage menu."
  (chat-test-with-temp-dir
   (let* ((state (make-chat-session :id "bounded-refresh-state"))
          (execution (make-chat-session :id "bounded-refresh-execution"))
          (profile (chat-agent-profile-resolve 'code))
          (run (chat-agent--run-create
                :session state :execution-session execution :profile profile)))
     (chat-session-set-working-directory state temp-dir)
     (chat-session-metadata-set state 'activeTaskId "task-1")
     (chat-session-metadata-set state 'code-enabled t)
     (chat-session-set-tool-config
      execution
      (list
       :enabled-tools chat-capability-programming-tools
       :advertised-tools
       (chat-capability--ordered-tool-union
        chat-capability-programming-base-tools
        chat-capability-programming-plan-tools
        chat-capability-programming-work-note-tools
        chat-capability-programming-goal-tools)))
     (chat-work-plan-skip
      state 'single-bounded-action
      :tool-name "files_replace" :task-id "task-1"
      :action-facts '((path . "sample.c")))
     (chat-capability-programming-refresh-tool-advertisement run)
     (let ((advertised
            (plist-get (chat-session-tool-config execution)
                       :advertised-tools)))
       (should (memq 'files_replace advertised))
       (dolist (tool '(programming_capability_activate
                       programming_work_note_upsert programming_goal_create
                       programming_plan_transition files_write files_patch
                       apply_patch programming_verification_run))
         (should-not (memq tool advertised))))
     (should-not
      (chat-work-plan-check-call
       state '(:name "files_replace" :arguments nil)))
     (chat-capability-programming-refresh-tool-advertisement run)
     (let ((advertised
            (plist-get (chat-session-tool-config execution)
                       :advertised-tools)))
       (should-not (memq 'files_replace advertised))
       (should (memq 'programming_plan_create advertised))
       (should-not (memq 'programming_compile_task advertised))
       (dolist (tool chat-capability-programming-verification-tools)
         (should (memq tool advertised)))))))

(ert-deftest chat-capability-registers-complete-plan-tool-surface ()
  "The programming profile exposes every durable plan operation."
  (let ((chat-tool-forge--registry (make-hash-table :test 'eq)))
    (chat-capability-register-tools)
    (dolist (id '(programming_plan_mode_enter
                  programming_plan_create programming_plan_read
                  programming_plan_list
                  programming_plan_update programming_plan_submit
                  programming_plan_transition
                  programming_plan_resume programming_plan_cancel
                  programming_plan_skip programming_plan_mode))
      (should (chat-tool-forge-get id))
      (should (memq id chat-capability-programming-tools)))))

(ert-deftest chat-capability-plan-tools-advertise-native-item-schema ()
  "Plan calls expose item structure instead of asking for encoded JSON."
  (let ((chat-tool-forge--registry (make-hash-table :test 'eq)))
    (chat-capability-register-tools)
    (dolist (id '(programming_plan_create programming_plan_update))
      (let* ((tool (chat-tool-forge-get id))
             (params (chat-forged-tool-parameters tool))
             (items (seq-find (lambda (param)
                                (equal (plist-get param :name) "items"))
                              params))
             (schema (plist-get items :items))
             (required (cdr (assoc 'required schema))))
        (should items)
        (should (equal "array" (plist-get items :type)))
        (should (= 1 (plist-get items :min-items)))
        (should (equal '("title" "acceptance")
                       (append required nil)))
        (should-not (seq-find
                     (lambda (param)
                       (equal (plist-get param :name) "items_json"))
                     params))))))

(ert-deftest chat-capability-progress-tools-advertise-native-evidence-schema ()
  "Plan and Goal progress accept Evidence IDs without encoded JSON."
  (let ((chat-tool-forge--registry (make-hash-table :test 'eq)))
    (chat-capability-register-tools)
    (dolist (id '(programming_plan_transition programming_goal_progress))
      (let* ((tool (chat-tool-forge-get id))
             (params (chat-forged-tool-parameters tool))
             (evidence (seq-find (lambda (param)
                                   (equal (plist-get param :name) "evidence"))
                                 params)))
        (should evidence)
        (should (equal "array" (plist-get evidence :type)))
        (should (equal '("string")
                       (plist-get evidence :accepted-types)))
        (should (equal "string"
                       (cdr (assoc 'type (plist-get evidence :items)))))
        (should-not (seq-find
                     (lambda (param)
                       (equal (plist-get param :name) "evidence_json"))
                     params))))
    (should (equal '("event-one" "verification-two")
                   (chat-capability--string-list
                    ["event-one" "verification-two"] "evidence")))
    (should (equal '("legacy-event")
                   (chat-capability--string-list
                    "[\"legacy-event\"]" "evidence")))
    (should-error
     (chat-capability--string-list '((id . "not-a-string")) "evidence"))))

(ert-deftest chat-capability-plan-transition-advertises-serial-revisions ()
  "Dependent plan transitions cannot safely share an observed revision."
  (let ((chat-tool-forge--registry (make-hash-table :test 'eq)))
    (chat-capability-register-tools)
    (let ((description
           (chat-forged-tool-description
            (chat-tool-forge-get 'programming_plan_transition))))
      (should (string-match-p "Transitions are serial" description))
      (should (string-match-p "returned revision" description)))))

(ert-deftest chat-capability-plan-tools-front-load-minimal-planning ()
  "Initial and staged contracts avoid a rejected probe and narrative TODOs."
  (let ((chat-tool-forge--registry (make-hash-table :test 'eq)))
    (chat-capability-register-tools)
    (let ((activation
           (chat-forged-tool-description
            (chat-tool-forge-get 'programming_capability_activate)))
          (creation
           (chat-forged-tool-description
            (chat-tool-forge-get 'programming_plan_create))))
      (should (string-match-p "programming_plan_create is already visible"
                              activation))
      (should (string-match-p "starts the first item" activation))
      (should (string-match-p "starts atomically" creation))
      (should (string-match-p "remain pending for user approval" creation))
      (should (string-match-p "control points, not a transcript" creation))
      (should (string-match-p "Combine related edits" creation)))))

(ert-deftest chat-capability-registers-bounded-goal-tool-surface ()
  "The Agent can advance Goals but cannot pause, resume or clear them."
  (let ((chat-tool-forge--registry (make-hash-table :test 'eq)))
    (chat-capability-register-tools)
    (dolist (id '(programming_goal_create programming_goal_read
                  programming_goal_list programming_goal_progress
                  programming_goal_block programming_goal_complete))
      (should (chat-tool-forge-get id))
      (should (memq id chat-capability-programming-tools)))
    (dolist (id '(programming_goal_pause programming_goal_resume
                  programming_goal_clear programming_goal_replace))
      (should-not (chat-tool-forge-get id))
      (should-not (memq id chat-capability-programming-tools)))))

(ert-deftest chat-capability-goal-tools-use-the-execution-session ()
  "Goal state follows the explicit execution session and structured contract."
  (chat-test-with-temp-dir
   (let ((ambient (make-chat-session :id "ambient-goal"))
         (execution (make-chat-session :id "execution-goal")))
     (chat-session-set-working-directory execution temp-dir)
     (let ((chat--current-session ambient)
           (chat-tool-caller-current-session execution)
           (chat-tool-caller-current-state-session execution))
       (let ((record
              (chat-capability-programming-goal-create
               "Finish Goal mode"
               "[{\"id\":\"tests\",\"title\":\"Tests pass\"}]"
               "All required tests have known evidence"
               "[\"Preserve compatibility\"]")))
         (should (equal "active" (cdr (assoc 'status record))))))
     (should (chat-goal-current execution))
     (should-not (chat-goal-current ambient)))))

(ert-deftest chat-capability-agent-can-enter-but-not-approve-plan-mode ()
  "The Agent entry tool shares state with slash/UI and exposes no approval tool."
  (chat-test-with-temp-dir
   (let ((ambient (make-chat-session :id "ambient-plan-mode"))
         (execution (make-chat-session :id "execution-plan-mode")))
     (let ((chat--current-session ambient)
           (chat-tool-caller-current-session execution)
           (chat-tool-caller-current-state-session execution))
       (let ((record (chat-capability-programming-plan-mode-enter)))
         (should (equal "researching" (cdr (assoc 'status record))))))
     (should (chat-plan-mode-active-p execution))
     (should-not (chat-plan-mode-current ambient))
     (dolist (id '(programming_plan_mode_approve
                   programming_plan_mode_reject
                   programming_plan_mode_cancel))
       (should-not (chat-tool-forge-get id))
       (should-not (memq id chat-capability-programming-tools))))))

(ert-deftest chat-capability-internal-work-state-does-not-require-approval ()
  "Plan and note bookkeeping is session state, not an external write."
  (let ((chat-tool-forge--registry (make-hash-table :test 'eq)))
    (chat-capability-register-tools)
    (dolist (id '(programming_capability_activate
                  programming_work_note_upsert
                  programming_work_note_resolve
                  programming_work_note_supersede
                  programming_work_note_archive
                  programming_work_note_delete
                  programming_goal_create
                  programming_goal_progress
                  programming_goal_block
                  programming_goal_complete
                  programming_plan_mode_enter
                  programming_plan_create
                  programming_plan_update
                  programming_plan_submit
                  programming_plan_transition
                  programming_plan_resume
                  programming_plan_cancel
                  programming_plan_skip))
      (should-not (chat-approval-tool-required-p
                   (chat-tool-forge-get id))))
    ;; Changing enforcement can weaken the task contract and stays gated.
    (should (chat-approval-tool-required-p
             (chat-tool-forge-get 'programming_plan_mode)))))

(provide 'test-chat-capability-packs)
;;; test-chat-capability-packs.el ends here
