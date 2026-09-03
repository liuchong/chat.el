;;; test-chat-plan-mode.el --- Tests for read-only Plan Mode -*- lexical-binding: t -*-

(require 'ert)
(require 'test-helper)
(require 'chat-plan-mode)
(require 'chat-goal)

(defun chat-plan-mode-test--session ()
  "Return one code-capable Plan Mode test session."
  (let ((session (chat-session-create "Plan Mode" 'kimi)))
    (chat-session-metadata-set session 'code-enabled t)
    session))

(defun chat-plan-mode-test--register-tool (id effects)
  "Register test tool ID with EFFECTS."
  (chat-tool-forge-register
   (make-chat-forged-tool
    :id id :name (symbol-name id) :description "Plan Mode test tool"
    :language 'elisp :parameters nil :owner 'test :sensitivity 'project
    :effects effects :compiled-function #'ignore :is-active t)))

(defun chat-plan-mode-test--call (id)
  "Return a tool call for ID."
  (list :name (symbol-name id) :arguments nil))

(ert-deftest chat-plan-mode-persists-read-only-state-across-reload ()
  "An active planning boundary survives session reload without approval."
  (chat-test-with-temp-dir
   (let* ((chat-session-auto-save t)
          (session (chat-plan-mode-test--session))
          (state (chat-plan-mode-enter session))
          (loaded (chat-session-load (chat-session-id session)))
          (restored (chat-plan-mode-current loaded)))
     (should (= 1 (chat-plan-mode-state-revision state)))
     (should (chat-plan-mode-state-enabled restored))
     (should (eq 'researching (chat-plan-mode-state-status restored)))
     (should-not (chat-plan-mode-state-approved-at restored))
     (let* ((plan
             (chat-work-plan-create
              session "Persisted proposal"
              '(((id . "inspect") (title . "Inspect")
                 (acceptance . "The relevant code is identified")))))
            (ready
             (chat-plan-mode-submit
              session (chat-work-plan-id plan)
              (chat-plan-mode-state-revision state)))
            (reloaded (chat-session-load (chat-session-id session)))
            (ready-restored (chat-plan-mode-current reloaded)))
       (should (eq 'ready (chat-plan-mode-state-status ready-restored)))
       (should (equal (chat-work-plan-id plan)
                      (chat-plan-mode-state-plan-id ready-restored)))
       (should (= (chat-work-plan-revision plan)
                  (chat-plan-mode-state-plan-revision ready-restored)))
       (should (= (chat-plan-mode-state-revision ready)
                  (chat-plan-mode-state-revision ready-restored)))
       (should
        (chat-plan-mode-check-call
         reloaded '(:name "test_write" :arguments nil)))))))

(ert-deftest chat-plan-mode-tool-boundary-allows-read-and-refuses-effects ()
  "The execution boundary fails closed for writes and unknown effects."
  (chat-test-with-temp-dir
   (let ((chat-tool-forge--registry (make-hash-table :test 'eq))
         (session (chat-plan-mode-test--session)))
     (chat-plan-mode-test--register-tool 'test_read '(read))
     (chat-plan-mode-test--register-tool 'test_web_read '(read outbound))
     (chat-plan-mode-test--register-tool 'test_write '(write))
     (chat-plan-mode-test--register-tool 'test_state '(state))
     (chat-plan-mode-test--register-tool 'test_destructive '(destructive))
     (chat-plan-mode-test--register-tool 'test_unknown nil)
     (chat-plan-mode-enter session)
     (should-not (chat-plan-mode-check-call
                  session (chat-plan-mode-test--call 'test_read)))
     (should-not (chat-plan-mode-check-call
                  session (chat-plan-mode-test--call 'test_web_read)))
     (dolist (id '(test_write test_state test_destructive test_unknown missing))
       (should (stringp
                (chat-plan-mode-check-call
                 session (chat-plan-mode-test--call id))))))))

(ert-deftest chat-plan-mode-allows-only-dedicated-planning-state-tools ()
  "Known notes, Goal progress and plan artifacts are the only state writes."
  (chat-test-with-temp-dir
   (let ((session (chat-plan-mode-test--session)))
     (chat-plan-mode-enter session)
     (dolist (name '("programming_work_note_upsert"
                     "programming_work_note_archive"
                     "programming_goal_progress"
                     "programming_goal_block"
                     "programming_plan_create"
                     "programming_plan_update"
                     "programming_plan_submit"))
       (should-not
        (chat-plan-mode-check-call session (list :name name :arguments nil))))
     (dolist (name '("programming_goal_create"
                     "programming_goal_complete"
                     "programming_plan_transition"
                     "programming_plan_resume"
                     "programming_plan_cancel"))
       (should
        (chat-plan-mode-check-call session (list :name name :arguments nil)))))))

(ert-deftest chat-plan-mode-submit-requires-complete-plan-and-user-approval ()
  "A ready plan remains read-only until an explicit user approval."
  (chat-test-with-temp-dir
   (let* ((session (chat-plan-mode-test--session))
          (state (chat-plan-mode-enter session))
          (plan (chat-work-plan-create
                 session "Implement"
                 '(((id . "inspect") (title . "Inspect")
                    (acceptance . "Relevant code is identified"))
                   ((id . "change") (title . "Change")
                    (dependencies . ["inspect"])
                    (acceptance . "Focused tests pass"))))))
     (setq state
           (chat-plan-mode-submit session (chat-work-plan-id plan)
                                  (chat-plan-mode-state-revision state)))
     (should (eq 'ready (chat-plan-mode-state-status state)))
     (should (chat-plan-mode-state-enabled state))
     (should (chat-plan-mode-check-call
              session '(:name "programming_plan_update" :arguments nil)))
     (should-not (chat-plan-mode-check-call
                  session '(:name "programming_plan_read" :arguments nil)))
     (setq state
           (chat-plan-mode-approve session
                                   (chat-plan-mode-state-revision state)))
     (should (eq 'approved (chat-plan-mode-state-status state)))
     (should-not (chat-plan-mode-state-enabled state))
     (should-not (chat-plan-mode-check-call
                  session '(:name "test_write" :arguments nil))))))

(ert-deftest chat-plan-mode-approval-refuses-a-changed-submitted-plan ()
  "Approval is tied to the exact submitted plan revision."
  (chat-test-with-temp-dir
   (let* ((session (chat-plan-mode-test--session))
          (state (chat-plan-mode-enter session))
          (plan
           (chat-work-plan-create
            session "Original plan"
            '(((id . "inspect") (title . "Inspect")
               (acceptance . "Relevant code is understood"))))))
     (setq state
           (chat-plan-mode-submit
            session (chat-work-plan-id plan)
            (chat-plan-mode-state-revision state)))
     (should (= (chat-plan-mode-state-plan-revision state)
                (chat-work-plan-revision plan)))
     (setq plan
           (chat-work-plan-update-future
            session (chat-work-plan-id plan) (chat-work-plan-revision plan)
            '(((id . "inspect-new") (title . "Inspect again")
               (acceptance . "New evidence is understood")))))
     (should-error
      (chat-plan-mode-approve session (chat-plan-mode-state-revision state))
      :type 'chat-plan-mode-invalid)
     (should (chat-plan-mode-active-p session))
     (should (eq (chat-plan-mode-state-status
                  (chat-plan-mode-current session))
                 'ready)))))

(ert-deftest chat-plan-mode-rejects-invalid-plan-and-stale-transitions ()
  "Submission validates acceptance and all transitions use revisions."
  (chat-test-with-temp-dir
   (let* ((chat-event-observer-functions nil)
          events
          (session (chat-plan-mode-test--session))
          (state (chat-plan-mode-enter session))
          (plan (chat-work-plan-create
                 session "Incomplete"
                 '(((id . "step") (title . "Step"))))))
     (chat-event-add-observer
      (lambda (event) (push (chat-event-type event) events)))
     (should-error
      (chat-plan-mode-submit session (chat-work-plan-id plan) 1)
      :type 'chat-plan-mode-invalid)
     (should-error (chat-plan-mode-cancel session 0)
                   :type 'chat-plan-mode-stale-revision)
     (should (memq 'plan-mode-conflicted events))
     (should (chat-plan-mode-state-enabled state)))))

(ert-deftest chat-plan-mode-rejection-feedback-returns-to-research ()
  "User rejection keeps the boundary active and records bounded feedback."
  (chat-test-with-temp-dir
   (let* ((session (chat-plan-mode-test--session))
          (state (chat-plan-mode-enter session))
          (plan (chat-work-plan-create
                 session "Proposal"
                 '(((id . "step") (title . "Step")
                    (acceptance . "Evidence is recorded"))))))
     (setq state (chat-plan-mode-submit session (chat-work-plan-id plan) 1))
     (setq state (chat-plan-mode-reject session 2 "Add a rollback step"))
     (should (chat-plan-mode-state-enabled state))
     (should (eq 'researching (chat-plan-mode-state-status state)))
     (should (equal "Add a rollback step"
                    (chat-plan-mode-state-feedback state))))))

(ert-deftest chat-plan-mode-is-independent-from-goal-and-legacy-plan-flag ()
  "Goal state and an old work.plan flag cannot approve or activate Plan Mode."
  (chat-test-with-temp-dir
   (let ((session (chat-plan-mode-test--session)))
     (chat-goal-create
      session "Durable objective"
      '(((id . "done") (title . "Done with evidence")))
      "Known evidence satisfies the criterion")
     (chat-session-metadata-set
      session 'work '((plan (status . "active") (title . "Legacy"))))
     (should-not (chat-plan-mode-current session))
     (chat-plan-mode-enter session)
     (should (eq 'active (chat-goal-status (chat-goal-current session))))
     (should (chat-plan-mode-active-p session)))))

(provide 'test-chat-plan-mode)
;;; test-chat-plan-mode.el ends here
