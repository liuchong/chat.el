;;; test-chat-goal.el --- Tests for durable cross-turn goals -*- lexical-binding: t -*-

(require 'ert)
(require 'cl-lib)
(require 'test-helper)
(require 'chat-context)
(require 'chat-goal)

(defun chat-goal-test--session ()
  "Return one Goal test session."
  (let ((session (chat-session-create "Goal" 'kimi)))
    (chat-session-metadata-set session 'working-directory
                               temporary-file-directory)
    session))

(defun chat-goal-test--criteria ()
  "Return two structured success criteria."
  '(((id . "implementation") (title . "Implementation is complete"))
    ((id . "verification") (title . "Canonical tests pass"))))

(defun chat-goal-test--create (session)
  "Create a standard Goal in SESSION."
  (chat-goal-create
   session "Finish the durable Goal mode" (chat-goal-test--criteria)
   "All required criteria have known verification evidence"
   :constraints '("Preserve existing behavior")
   :non-goals '("Do not publish a release")
   :sources '("user-request")
   :project-root temporary-file-directory))

(ert-deftest chat-goal-contract-persists-and-reloads ()
  "Goal identity and completion contract survive a session reload."
  (chat-test-with-temp-dir
   (let* ((chat-session-auto-save t)
          (session (chat-goal-test--session))
          (goal (chat-goal-test--create session))
          (loaded (chat-session-load (chat-session-id session)))
          (restored (chat-goal-current loaded)))
     (should (equal (chat-goal-id goal) (chat-goal-id restored)))
     (should (= 1 (chat-goal-revision restored)))
     (should (eq 'active (chat-goal-status restored)))
     (should (equal (chat-goal-stopping-condition goal)
                    (chat-goal-stopping-condition restored)))
     (should (= 2 (length (chat-goal-success-criteria restored))))
     (should (equal '("Preserve existing behavior")
                    (chat-goal-constraints restored))))))

(ert-deftest chat-goal-refuses-incomplete-contracts ()
  "A Goal needs an objective, criteria and stopping condition."
  (chat-test-with-temp-dir
   (let ((session (chat-goal-test--session)))
     (should-error
      (chat-goal-create session "" (chat-goal-test--criteria) "Stop")
      :type 'chat-goal-invalid)
     (should-error
      (chat-goal-create session "Objective" nil "Stop")
      :type 'chat-goal-invalid)
     (should-error
      (chat-goal-create session "Objective" (chat-goal-test--criteria) "")
      :type 'chat-goal-invalid))))

(ert-deftest chat-goal-project-scope-fails-closed-without-content-leakage ()
  "A persisted Goal cannot advance or project details in another project."
  (chat-test-with-temp-dir
   (let* ((session (chat-goal-test--session))
          (root-a (expand-file-name "project-a" temp-dir))
          (root-b (expand-file-name "project-b" temp-dir))
          (root-a-link (expand-file-name "project-a-link" temp-dir))
          (objective "private project-a objective")
          goal fragment projection)
     (make-directory root-a t)
     (make-directory root-b t)
     (make-symbolic-link root-a root-a-link)
     (chat-session-set-working-directory session root-a)
     (setq goal
           (chat-goal-create
            session objective (chat-goal-test--criteria) "Stop safely"
            :project-root root-a))
     (chat-session-set-working-directory session root-a-link)
     (should (chat-goal-project-in-scope-p session goal))
     (setq goal
           (chat-goal-progress
            session (chat-goal-id goal) (chat-goal-revision goal)
            :checkpoint "private checkpoint"))
     (chat-session-set-working-directory session root-b)
     (should-error
      (chat-goal-progress session (chat-goal-id goal)
                          (chat-goal-revision goal) :message "continue")
      :type 'chat-goal-scope-mismatch)
     (should-error
      (chat-goal-complete session (chat-goal-id goal)
                          (chat-goal-revision goal))
      :type 'chat-goal-scope-mismatch)
     (setq fragment (chat-goal-context-fragment session)
           projection (chat-goal-ui-projection session))
     (should (eq (cdr (assoc 'scopeMismatch
                             (chat-context-fragment-metadata fragment))) t))
     (should-not (string-match-p objective
                                 (chat-context-fragment-payload fragment)))
     (should (plist-get projection :scope-mismatch))
     (should-not (string-match-p objective
                                 (plist-get projection :objective)))
     (should-not (plist-get projection :checkpoint))
     (should-not (plist-get projection :blocker-reason))
     (should-not (plist-get projection :unblock-condition))
     (should-not (plist-get projection :needs-attention))
     (let ((chat--current-session session))
       (let ((report (chat-ui--goal-report goal)))
         (should-not (string-match-p objective report))
         (should-not (string-match-p "private checkpoint" report)))))))

(ert-deftest chat-goal-plan-notes-survive-two-compactions-and-restart ()
  "Goal, TODO plan and notes remain structured across compaction and reload."
  (chat-test-with-temp-dir
   (let* ((chat-session-auto-save nil)
          (chat-work-context-directory
           (expand-file-name "work-context" temp-dir))
          (chat-work-context--stores (make-hash-table :test 'equal))
          (session (chat-goal-test--session))
          (session-id (chat-session-id session))
          (goal (chat-goal-test--create session))
          (plan
           (chat-work-plan-create
            session "Implement and verify"
            '(((id . "implement") (title . "Implement")
               (acceptance . "Implementation is complete"))
              ((id . "verify") (title . "Verify")
               (dependencies . ["implement"])
               (acceptance . "Canonical tests pass")))))
          (note
           (chat-work-note-upsert
            session-id "decision.scope" '((choice . "session-and-project"))
            :kind 'decision :scope 'session :scope-id session-id
            :source-kind 'agent :source-id "turn:1")))
     (setf (chat-session-messages session)
           (cl-loop for index from 1 to 20
                    collect
                    (make-chat-message
                     :id (format "before-%d" index)
                     :role (if (cl-oddp index) :user :assistant)
                     :content (format "message %d %s"
                                      index (make-string 180 ?x)))))
     (should (chat-context-compact-session session 100 nil "goal-test-1"))
     (setf (chat-session-messages session)
           (append
            (chat-session-messages session)
            (cl-loop for index from 1 to 12
                     collect
                     (make-chat-message
                      :id (format "after-%d" index)
                      :role (if (cl-oddp index) :user :assistant)
                      :content (format "later %d %s"
                                       index (make-string 180 ?y))))))
     (should (chat-context-compact-session session 100 nil "goal-test-2"))
     (should (>= (length (chat-session-summaries session)) 2))
     (chat-session-save session)
     (clrhash chat-work-context--stores)
     (let* ((loaded (chat-session-load session-id))
            (restored-goal (chat-goal-current loaded))
            (restored-plan (chat-work-plan-current loaded t))
            (note-fragments
             (chat-work-note-fragments
              session-id `(:session-id ,session-id
                            :project-root ,temporary-file-directory)))
            (goal-fragment (chat-goal-context-fragment loaded)))
       (should (eq (chat-goal-status restored-goal) 'active))
       (should (equal (chat-work-plan-id restored-plan)
                      (chat-work-plan-id plan)))
       (should (member (chat-work-plan-id plan)
                       (chat-goal-plan-ids restored-goal)))
       (should (equal (chat-work-note-id note)
                      (chat-context-fragment-source-id (car note-fragments))))
       (should (string-match-p "decision.scope"
                               (chat-context-fragment-payload
                                (car note-fragments))))
       (should (eq (chat-context-fragment-residency goal-fragment)
                   'protected))
       (should (string-match-p "Finish the durable Goal mode"
                               (chat-context-fragment-payload
                                goal-fragment)))))))

(ert-deftest chat-goal-progress-requires-known-scoped-evidence ()
  "Criterion satisfaction rejects unknown evidence and accepts known evidence."
  (chat-test-with-temp-dir
   (let* ((session (chat-goal-test--session))
          (goal (chat-goal-test--create session))
          (chat-work-plan-evidence-resolver-functions
           (list (lambda (candidate task-id evidence-id)
                   (and (eq candidate session) (null task-id)
                        (member evidence-id '("test:implementation"
                                              "test:verification")))))))
     (should-error
      (chat-goal-progress
       session (chat-goal-id goal) 1
       :criterion-id "implementation" :evidence '("unknown:evidence"))
      :type 'chat-goal-evidence-invalid)
     (setq goal
           (chat-goal-progress
            session (chat-goal-id goal) 1
            :checkpoint "Core state machine implemented"
            :message "Implementation evidence recorded"
            :criterion-id "implementation"
            :evidence '("test:implementation")
            :plan-id "plan-1" :task-id "task-1"))
     (should (= 2 (chat-goal-revision goal)))
     (should (equal "Core state machine implemented"
                    (chat-goal-current-checkpoint goal)))
     (should (equal '("plan-1") (chat-goal-plan-ids goal)))
     (should (equal '("task-1") (chat-goal-task-ids goal)))
     (should (eq 'satisfied
                 (chat-goal-criterion-status
                  (car (chat-goal-success-criteria goal))))))))

(ert-deftest chat-goal-completion-is-deterministic-and-evidence-backed ()
  "Self-reported completion cannot bypass required criteria."
  (chat-test-with-temp-dir
   (let* ((session (chat-goal-test--session))
          (goal (chat-goal-test--create session))
          (chat-work-plan-evidence-resolver-functions
           (list (lambda (_session _task-id evidence-id)
                   (member evidence-id '("test:implementation"
                                         "test:verification"))))))
     (should-error (chat-goal-complete session (chat-goal-id goal) 1)
                   :type 'chat-goal-evidence-invalid)
     (setq goal
           (chat-goal-progress
            session (chat-goal-id goal) 1
            :criterion-id "implementation"
            :evidence '("test:implementation")))
     (should-error (chat-goal-complete session (chat-goal-id goal) 2)
                   :type 'chat-goal-evidence-invalid)
     (setq goal
           (chat-goal-progress
            session (chat-goal-id goal) 2
            :criterion-id "verification"
            :evidence '("test:verification")))
     (setq goal (chat-goal-complete session (chat-goal-id goal) 3))
     (should (eq 'completed (chat-goal-status goal)))
     (should (= 4 (chat-goal-revision goal)))
     (should (chat-goal-completed-at goal)))))

(ert-deftest chat-goal-pause-block-resume-and-stale-revision ()
  "Lifecycle controls preserve progress and reject stale writers."
  (chat-test-with-temp-dir
   (let* ((session (chat-goal-test--session))
          (goal (chat-goal-test--create session)))
     (setq goal (chat-goal-pause session (chat-goal-id goal) 1))
     (should (eq 'paused (chat-goal-status goal)))
     (should-error
      (chat-goal-progress session (chat-goal-id goal) 2 :message "advance")
      :type 'chat-goal-transition-invalid)
     (should-error (chat-goal-resume session (chat-goal-id goal) 1)
                   :type 'chat-goal-stale-revision)
     (setq goal (chat-goal-resume session (chat-goal-id goal) 2))
     (setq goal
           (chat-goal-block session (chat-goal-id goal) 3
                            "Needs user credentials"
                            "User supplies a scoped credential"))
     (should (eq 'blocked (chat-goal-status goal)))
     (should (equal "Needs user credentials"
                    (chat-goal-blocker-reason goal)))
     (setq goal (chat-goal-resume session (chat-goal-id goal) 4))
     (should (eq 'active (chat-goal-status goal)))
     (should-not (chat-goal-blocker-reason goal)))))

(ert-deftest chat-goal-clear-preserves-history ()
  "Clear removes only the selected pointer."
  (chat-test-with-temp-dir
   (let* ((session (chat-goal-test--session))
          (goal (chat-goal-test--create session)))
     (chat-goal-clear session)
     (should-not (chat-goal-current session))
     (should (chat-goal-find session (chat-goal-id goal)))
     (should (= 1 (length (chat-goal-list session)))))))

(ert-deftest chat-goal-links-plans-and-runtime-tasks-without-completing ()
  "Plan and task lifecycle links advance revision but never complete a Goal."
  (chat-test-with-temp-dir
   (let* ((session (chat-goal-test--session))
          (goal (chat-goal-test--create session)))
     (chat-goal-link-plan session "plan-1")
     (chat-goal-link-task session "task-1")
     (setq goal (chat-goal-current session))
     (should (= 3 (chat-goal-revision goal)))
     (should (equal '("plan-1") (chat-goal-plan-ids goal)))
     (should (equal '("task-1") (chat-goal-task-ids goal)))
     (should (eq 'active (chat-goal-status goal)))
     (should-not (chat-goal-completion-ready-p session goal)))))

(ert-deftest chat-goal-migrates-legacy-records-to-paused-contracts ()
  "Legacy title/status records cannot become active unverifiable Goals."
  (chat-test-with-temp-dir
   (let ((session (chat-goal-test--session)))
     (chat-session-metadata-set
      session 'work
      '((plan . nil) (todos . nil)
        (goals . [((id . "legacy-1") (title . "Ship it")
                   (status . "active"))])
        (workflows . nil)))
     (let ((goal (chat-goal-current session)))
       (should (equal "legacy-1" (chat-goal-id goal)))
       (should (eq 'paused (chat-goal-status goal)))
       (should (equal "Ship it" (chat-goal-objective goal)))
       (should (chat-goal--get (chat-goal-metadata goal) 'legacy))
       (should (= 1 (chat-session-metadata-get session 'goalMigrationVersion)))
       (should-not
        (chat-goal--list
         (chat-goal--get (chat-session-metadata-get session 'work) 'goals)))))))

(ert-deftest chat-goal-migration-is-once-and-preserves-new-records ()
  "Migration marks empty sessions and merges legacy data without replacement."
  (chat-test-with-temp-dir
   (let ((empty (chat-goal-test--session)))
     (should-not (chat-goal-current empty))
     (should (= 1 (chat-session-metadata-get empty 'goalMigrationVersion)))
     (should (= 1 (chat-session-metadata-get
                   (chat-session-load (chat-session-id empty))
                   'goalMigrationVersion))))
   (let* ((session (chat-goal-test--session))
          (goal (chat-goal-test--create session)))
     (chat-session-metadata-set session 'goalMigrationVersion nil)
     (chat-session-metadata-set
      session 'work
      '((goals . [((id . "legacy-2") (title . "Older goal")
                   (status . "pending"))
                  ((id . nil) (title . "Colliding goal")
                   (status . "pending"))])))
     (setcdr (assoc 'id
                    (aref (cdr (assoc 'goals
                                      (chat-session-metadata-get session 'work)))
                          1))
             (chat-goal-id goal))
     (let ((goals (chat-goal-list session)))
       (should (= 2 (length goals)))
       (should (chat-goal-find session (chat-goal-id goal)))
       (should (chat-goal-find session "legacy-2"))
       (should (equal "Finish the durable Goal mode"
                      (chat-goal-objective
                       (chat-goal-find session (chat-goal-id goal)))))
       (should (equal (chat-goal-id goal)
                      (chat-goal-id (chat-goal-current session))))))))

(ert-deftest chat-goal-projection-is-protected-bounded-and-state-aware ()
  "The request projection preserves the contract without copying full logs."
  (chat-test-with-temp-dir
   (let* ((session (chat-goal-test--session))
          (goal (chat-goal-test--create session))
          (fragment (chat-goal-context-fragment session)))
     (should (eq 'objective (chat-context-fragment-kind fragment)))
     (should (eq 'protected (chat-context-fragment-residency fragment)))
     (should (eq 'goal (chat-context-fragment-source-kind fragment)))
     (should (string-match-p "Stopping condition"
                             (chat-context-fragment-payload fragment)))
     (should (string-match-p "Canonical tests pass"
                             (chat-context-fragment-payload fragment)))
     (setq goal (chat-goal-pause session (chat-goal-id goal) 1))
     (setq fragment (chat-goal-context-fragment session))
     (should (string-match-p "Do not advance or resume"
                             (chat-context-fragment-payload fragment))))))

(ert-deftest chat-goal-events-are-bounded-and-omit-objective-text ()
  "Goal audit events record facts without copying sensitive contract text."
  (chat-test-with-temp-dir
   (let* ((chat-session-wire--sequences (make-hash-table :test 'equal))
          (chat-session-wire--sizes (make-hash-table :test 'equal))
          (session (chat-goal-test--session))
          (goal (chat-goal-create
                 session "Sensitive objective" (chat-goal-test--criteria)
                 "Sensitive stopping condition")))
     (chat-goal-pause session (chat-goal-id goal) 1)
     (let ((records (chat-session-wire-read-all (chat-session-id session))))
       (should (equal '("goal-created" "goal-selected" "goal-paused")
                      (mapcar (lambda (record) (alist-get 'kind record))
                              records)))
       (dolist (record records)
         (should-not
          (string-match-p "Sensitive" (prin1-to-string record))))))))

(provide 'test-chat-goal)
;;; test-chat-goal.el ends here
