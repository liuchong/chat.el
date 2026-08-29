;;; test-chat-work-plan.el --- Tests for durable work plans -*- lexical-binding: t -*-

(require 'ert)
(require 'cl-lib)
(require 'test-helper)
(require 'chat-work-plan)
(require 'chat-execution)
(require 'chat-session-wire)

(defun chat-work-plan-test--session ()
  "Return one code-capable test session."
  (let ((session (chat-session-create "Plan" 'kimi)))
    (chat-session-metadata-set session 'code-enabled t)
    (chat-session-metadata-set session 'activeTaskId "task-1")
    session))

(defun chat-work-plan-test--items (&optional third)
  "Return a small dependency-ordered item description list."
  (append
   '(((id . "inspect") (title . "Inspect")
      (acceptance . "Relevant code is understood"))
     ((id . "change") (title . "Change") (dependencies . ["inspect"])
      (acceptance . "The requested behavior works")))
   (when third
     '(((id . "verify") (title . "Verify") (dependencies . ["change"])
        (acceptance . "Tests pass"))))))

(ert-deftest chat-work-plan-persists-and-reloads-with-task-scope ()
  "A plan is session durable and retains its foreground task identity."
  (chat-test-with-temp-dir
   (let* ((chat-session-auto-save t)
          (session (chat-work-plan-test--session))
          (plan (chat-work-plan-create
                 session "Implement reliable plans"
                 (chat-work-plan-test--items))))
     (should (= 1 (chat-work-plan-revision plan)))
     (should (equal "task-1" (chat-work-plan-task-id plan)))
     (let* ((loaded (chat-session-load (chat-session-id session)))
            (restored (chat-work-plan-current loaded nil)))
       (should (equal (chat-work-plan-id plan) (chat-work-plan-id restored)))
       (should (= 2 (length (chat-work-plan-items restored))))
       (should (equal "inspect"
                      (car (chat-work-plan-item-dependencies
                            (cadr (chat-work-plan-items restored))))))))))

(ert-deftest chat-work-plan-refuses-empty-duplicate-and-cyclic-plans ()
  "Plan construction rejects states that cannot guide execution."
  (chat-test-with-temp-dir
   (let ((session (chat-work-plan-test--session)))
     (should-error (chat-work-plan-create session "Empty" nil)
                   :type 'chat-work-plan-invalid)
     (should-error
      (chat-work-plan-create
       session "Duplicate"
       '(((id . "same") (title . "One"))
         ((id . "same") (title . "Two"))))
      :type 'chat-work-plan-invalid)
     (should-error
      (chat-work-plan-create
       session "Cycle"
       '(((id . "a") (title . "A") (dependencies . ["b"]))
         ((id . "b") (title . "B") (dependencies . ["a"]))))
      :type 'chat-work-plan-invalid))))

(ert-deftest chat-work-plan-enforces-dependencies-and-one-active-item ()
  "Only one dependency-ready item may be in progress."
  (chat-test-with-temp-dir
   (let* ((session (chat-work-plan-test--session))
          (plan (chat-work-plan-create session "Ordered"
                                       (chat-work-plan-test--items))))
     (should-error
      (chat-work-plan-transition-item
       session (chat-work-plan-id plan) 1 "change" 'in-progress)
      :type 'chat-work-plan-invalid)
     (setq plan (chat-work-plan-transition-item
                 session (chat-work-plan-id plan) 1 "inspect" 'in-progress))
     (should-error
      (chat-work-plan-transition-item
       session (chat-work-plan-id plan) 2 "change" 'in-progress)
      :type 'chat-work-plan-invalid)
     (should (eq 'in-progress
                 (chat-work-plan-item-status
                  (car (chat-work-plan-items plan))))))))

(ert-deftest chat-work-plan-completion-requires-resolvable-evidence ()
  "Terminal success is backed by a known runtime evidence id."
  (chat-test-with-temp-dir
   (let* ((session (chat-work-plan-test--session))
          (plan (chat-work-plan-create
                 session "Evidence"
                 '(((id . "first") (title . "First"))
                   ((id . "next") (title . "Next")
                    (dependencies . ["first"])))))
          (chat-work-plan-evidence-resolver-functions
           (list (lambda (candidate task-id evidence-id)
                   (and (eq candidate session)
                        (equal task-id "task-1")
                        (equal evidence-id "test:passed"))))))
     (setq plan (chat-work-plan-transition-item
                 session (chat-work-plan-id plan) 1 "first" 'in-progress))
     (should-error
      (chat-work-plan-transition-item
       session (chat-work-plan-id plan) 2 "first" 'completed
       :evidence '("unknown:evidence"))
      :type 'chat-work-plan-invalid)
     (setq plan (chat-work-plan-transition-item
                 session (chat-work-plan-id plan) 2 "first" 'completed
                 :evidence '("test:passed")))
     (should (eq 'active (chat-work-plan-status plan)))
     (should (equal '("test:passed")
                    (chat-work-plan-item-evidence
                     (car (chat-work-plan-items plan)))))
     (let ((fragment (chat-work-plan-context-fragment session "task-1" 2)))
       (should (string-match-p "New evidence: test:passed"
                               (chat-context-fragment-payload fragment)))))))

(ert-deftest chat-work-plan-rejects-evidence-from-another-session-or-task ()
  "A globally known ID cannot complete work in the wrong scope."
  (chat-test-with-temp-dir
   (let* ((session (chat-work-plan-test--session))
          (chat-execution--records (make-hash-table :test 'equal))
          (foreign-request
           (chat-execution-request-create
            :id "execution:foreign" :session-id "other-session"
            :task-id "task-1"))
          (foreign-record
           (chat-execution-record-create
            :id "execution:foreign" :request foreign-request
            :status 'completed)))
     (puthash "execution:foreign" foreign-record chat-execution--records)
     (should-not
      (chat-work-plan-evidence-known-p
       session "task-1" "execution:foreign"))
     (let* ((local-request
             (chat-execution-request-create
              :id "execution:local" :session-id (chat-session-id session)
              :task-id "task-1"))
            (local-record
             (chat-execution-record-create
              :id "execution:local" :request local-request
              :status 'completed)))
       (puthash "execution:local" local-record chat-execution--records)
       (should
       (chat-work-plan-evidence-known-p
        session "task-1" "execution:local"))))))

(ert-deftest chat-work-plan-resolves-tool-events-by-agent-task-scope ()
  "A post-tool event is evidence only for its owning Agent task."
  (chat-test-with-temp-dir
   (let ((session (chat-work-plan-test--session)))
     (cl-letf (((symbol-function 'chat-session-wire-read-all)
                (lambda (session-id)
                  (should (equal session-id (chat-session-id session)))
                  '(((event_id . "event-tool-result")
                     (task_id . "tool-call-id")
                     (agent_task_id . "task-1"))))))
       (should
        (chat-work-plan-evidence-known-p
         session "task-1" "event-tool-result"))
       (should-not
        (chat-work-plan-evidence-known-p
         session "task-2" "event-tool-result"))))))

(ert-deftest chat-work-plan-stale-write-does-not-change-session-metadata ()
  "A stale writer fails before touching the persisted projection."
  (chat-test-with-temp-dir
   (let* ((session (chat-work-plan-test--session))
          (plan (chat-work-plan-create session "Lock"
                                       (chat-work-plan-test--items)))
          (before (copy-tree (chat-session-metadata session))))
     (should-error
      (chat-work-plan-transition-item
       session (chat-work-plan-id plan) 0 "inspect" 'in-progress)
      :type 'chat-work-plan-stale-revision)
     (should (equal before (chat-session-metadata session))))))

(ert-deftest chat-work-plan-transitions-are-session-auditable-and-bounded ()
  "Plan facts enter the session wire without copying objective text."
  (chat-test-with-temp-dir
   (let* ((chat-session-wire--sequences (make-hash-table :test 'equal))
          (chat-session-wire--sizes (make-hash-table :test 'equal))
          (session (chat-work-plan-test--session))
          (plan (chat-work-plan-create
                 session "Sensitive objective body"
                 '(((id . "audit") (title . "Audit"))))))
     (chat-work-plan-transition-item
      session (chat-work-plan-id plan) 1 "audit" 'in-progress)
     (let* ((records (chat-session-wire-read-all (chat-session-id session)))
            (kinds (mapcar (lambda (record) (alist-get 'kind record)) records)))
       (should (equal '("plan-created" "plan-item-started") kinds))
       (dolist (record records)
         (should (equal (chat-session-id session)
                        (alist-get 'session_id record)))
         (should-not
          (string-match-p "Sensitive objective body"
                          (prin1-to-string record))))))))

(ert-deftest chat-work-plan-update-replaces-only-pending-future-tail ()
  "Plan updates preserve started history and validate the new future DAG."
  (chat-test-with-temp-dir
   (let* ((session (chat-work-plan-test--session))
          (plan (chat-work-plan-create session "Adapt"
                                       (chat-work-plan-test--items t))))
     (setq plan (chat-work-plan-transition-item
                 session (chat-work-plan-id plan) 1 "inspect" 'in-progress))
     (setq plan (chat-work-plan-update-future
                 session (chat-work-plan-id plan) 2
                 '(((id . "replacement") (title . "Replacement")
                    (dependencies . ["inspect"])))
                 :objective "Adapted objective"))
     (should (= 3 (chat-work-plan-revision plan)))
     (should (equal "Adapted objective" (chat-work-plan-objective plan)))
     (should (equal '("inspect" "replacement")
                    (mapcar #'chat-work-plan-item-id
                            (chat-work-plan-items plan))))
     (should (eq 'in-progress
                 (chat-work-plan-item-status
                  (car (chat-work-plan-items plan)))))
     (should-error
      (chat-work-plan-update-future
       session (chat-work-plan-id plan) 2
       '(((id . "stale") (title . "Stale"))))
      :type 'chat-work-plan-stale-revision))))

(ert-deftest chat-work-plan-list-is-newest-first-and-detached ()
  "History listing cannot mutate the authoritative session projection."
  (chat-test-with-temp-dir
   (let* ((session (chat-work-plan-test--session))
          (first (chat-work-plan-create
                  session "First" '(((id . "one") (title . "One"))))))
     (chat-work-plan-cancel session (chat-work-plan-id first) 1)
     (let* ((second (chat-work-plan-create
                     session "Second" '(((id . "two") (title . "Two")))))
            (listed (chat-work-plan-list session)))
       (should (equal (chat-work-plan-id second)
                      (chat-work-plan-id (car listed))))
       (setf (chat-work-plan-objective (car listed)) "Changed copy")
       (should (equal "Second"
                      (chat-work-plan-objective
                       (chat-work-plan-current session nil))))))))

(ert-deftest chat-work-plan-restart-blocks-and-explicit-resume-recovers ()
  "An interrupted in-progress item never resumes invisibly."
  (chat-test-with-temp-dir
   (let* ((session (chat-work-plan-test--session))
          (chat-work-plan--runtime-id "runtime-a")
          (plan (chat-work-plan-create
                 session "Restart"
                 '(((id . "item") (title . "Item"))))))
     (setq plan (chat-work-plan-transition-item
                 session (chat-work-plan-id plan) 1 "item" 'in-progress))
     (let ((chat-work-plan--runtime-id "runtime-b"))
       (setq plan (chat-work-plan-current session t))
       (should (eq 'blocked (chat-work-plan-status plan)))
       (should (equal "interrupted"
                      (chat-work-plan-item-blocker-reason
                       (car (chat-work-plan-items plan)))))
       (should-error
        (chat-work-plan-transition-item
         session (chat-work-plan-id plan) (chat-work-plan-revision plan)
         "item" 'in-progress)
        :type 'chat-work-plan-invalid)
       (setq plan (chat-work-plan-resume
                   session (chat-work-plan-id plan)
                   (chat-work-plan-revision plan)))
       (should (eq 'active (chat-work-plan-status plan)))
       (should (eq 'pending
                   (chat-work-plan-item-status
                    (car (chat-work-plan-items plan)))))))))

(ert-deftest chat-work-plan-gate-covers-mutations-and-consumes-skip-once ()
  "The code mutation gate requires a plan and consumes a narrow skip once."
  (chat-test-with-temp-dir
   (let ((session (chat-work-plan-test--session))
         (call '(:name "files_write" :arguments nil)))
     (should (stringp (chat-work-plan-check-call session call)))
     (chat-work-plan-skip session 'single-bounded-action
                          :tool-name "files_write"
                          :action-facts '((path . "one.txt")))
     (should-not
      (chat-work-plan-check-call
       session '(:name "files_patch" :arguments nil)))
     (should-not
      (chat-work-plan-check-call
       session '(:name "programming_compile_task" :arguments nil)))
     (should-not
      (chat-work-plan-check-call
       session '(:name "programming_verification_run" :arguments nil)))
     (should (stringp (chat-work-plan-check-call session call)))
     (chat-work-plan-create session "Write"
                            '(((id . "write") (title . "Write"))))
     (should (string-match-p "Plan item required"
                             (chat-work-plan-check-call session call)))
     (let ((plan (chat-work-plan-current session nil)))
       (chat-work-plan-transition-item
        session (chat-work-plan-id plan) (chat-work-plan-revision plan)
        "write" 'in-progress))
     (should-not (chat-work-plan-check-call session call)))))

(ert-deftest chat-work-plan-required-and-off-modes-are-explicit ()
  "Required forbids skips while off disables the mutation gate."
  (chat-test-with-temp-dir
   (let ((session (chat-work-plan-test--session)))
     (chat-work-plan-set-mode session 'required)
     (should-error (chat-work-plan-skip session 'read-only)
                   :type 'chat-work-plan-required)
     (should (stringp
              (chat-work-plan-check-call
               session '(:name "files_read" :arguments nil))))
     (chat-work-plan-set-mode session 'off)
     (should-not
      (chat-work-plan-check-call
       session '(:name "programming_verification_run" :arguments nil))))))

(ert-deftest chat-work-plan-does-not-cross-foreground-task-scope ()
  "A plan for one foreground task cannot authorize or enter another."
  (chat-test-with-temp-dir
   (let* ((session (chat-work-plan-test--session))
          (plan (chat-work-plan-create
                 session "Scoped" '(((id . "item") (title . "Item"))))))
     (setq plan (chat-work-plan-transition-item
                 session (chat-work-plan-id plan) 1 "item" 'in-progress))
     (chat-session-metadata-set session 'activeTaskId "task-2")
     (should (stringp
              (chat-work-plan-check-call
               session '(:name "files_write" :arguments nil))))
     (should-not (chat-work-plan-context-fragment session "task-2")))))

(ert-deftest chat-work-plan-context-is-bounded-and-task-scoped ()
  "Only a compact active slice enters model context."
  (chat-test-with-temp-dir
   (let* ((session (chat-work-plan-test--session))
          (plan (chat-work-plan-create session "上下文计划"
                                       (chat-work-plan-test--items t)))
          (fragment (chat-work-plan-context-fragment session "task-1")))
     (should fragment)
     (should (eq 'task (chat-context-fragment-scope fragment)))
     (should (equal "task-1" (chat-context-fragment-scope-id fragment)))
     (should (string-match-p "Current item 1/3: Inspect"
                             (chat-context-fragment-payload fragment)))
     (should (string-match-p "Remaining: Change; Verify"
                             (chat-context-fragment-payload fragment)))
     (should (equal (chat-work-plan-id plan)
                    (chat-context-fragment-source-id fragment))))))

(ert-deftest chat-work-plan-context-has-an-independent-hard-limit ()
  "Large plan fields cannot turn the active slice into prompt history."
  (chat-test-with-temp-dir
   (let* ((session (chat-work-plan-test--session))
          (chat-work-plan-max-projection-chars 512)
          (_plan
           (chat-work-plan-create
            session (make-string 4000 ?o)
            `(((id . "large") (title . ,(make-string 2000 ?t))
               (acceptance . ,(make-string 3000 ?a))))))
          (fragment (chat-work-plan-context-fragment session "task-1")))
     (should (<= (length (chat-context-fragment-payload fragment)) 512)))))

(ert-deftest chat-work-plan-refuses-newer-unsupported-schema ()
  "Unknown durable schemas fail closed instead of being guessed."
  (should-error
   (chat-work-plan-from-alist
    '((schemaVersion . 99) (id . "future") (revision . 1)
      (sessionId . "session") (objective . "Future")
      (mode . "auto") (status . "active")
      (items . [((schemaVersion . 99) (id . "item")
                 (title . "Item") (order . 0) (status . "pending"))])))
   :type 'chat-work-plan-invalid))

(provide 'test-chat-work-plan)
;;; test-chat-work-plan.el ends here
