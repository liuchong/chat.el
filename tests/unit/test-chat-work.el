;;; test-chat-work.el --- Tests for chat-work.el -*- lexical-binding: t -*-

(require 'ert)
(require 'test-helper)
(require 'chat-work)

(ert-deftest chat-work-background-task-runs-and-captures-output ()
  "Test background tasks run asynchronously and keep bounded output."
  (chat-test-with-temp-dir
   (let ((chat-work-directory temp-dir)
         (chat-work--tasks (make-hash-table :test 'equal))
         (chat-work-notify-task-completion nil)
         finished)
     (let ((chat-work-task-finished-hook
            (list (lambda (task)
                    (setq finished (chat-work-task-id task))))))
       (let* ((summary (chat-work-task-start "printf hello"
                                              default-directory))
              (id (cdr (assoc 'id summary)))
              (task (gethash id chat-work--tasks)))
         (while (and (process-live-p (chat-work-task-process task)))
           (accept-process-output (chat-work-task-process task) 0.1))
         (should (eq (chat-work-task-status task) 'succeeded))
         (should (equal finished id))
         (should (string= (chat-work-task-output id) "hello"))
         (should (file-exists-p
                  (expand-file-name "tasks.json" temp-dir))))))))

(ert-deftest chat-work-background-task-stop-cancels-process ()
  "Test background task stop marks a running process cancelled."
  (chat-test-with-temp-dir
   (let ((chat-work-directory temp-dir)
         (chat-work--tasks (make-hash-table :test 'equal))
         (chat-work-notify-task-completion nil)
         finished)
     (let ((chat-work-task-finished-hook
            (list (lambda (task)
                    (setq finished (chat-work-task-id task))))))
       (let* ((summary (chat-work-task-start "sleep 5" default-directory))
              (id (cdr (assoc 'id summary)))
              (task (gethash id chat-work--tasks)))
         (should (process-live-p (chat-work-task-process task)))
         (chat-work-task-stop id)
         (should (eq (chat-work-task-status task) 'cancelled))
         (should (equal finished id)))))))

(ert-deftest chat-work-session-records-persist-in-session-metadata ()
  "Test plan, TODO, and goal records are session-local and durable."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (chat-tool-caller-current-session
           (chat-session-create "Work Records" 'kimi))
          (session-id (chat-session-id chat-tool-caller-current-session)))
     (chat-work-plan-enter "Investigate")
     (let ((todo (chat-work-todo-add "Write tests"))
           (goal (chat-work-goal-add "Ship stage")))
       (chat-work-todo-update (cdr (assoc 'id todo)) "done")
       (chat-work-goal-update (cdr (assoc 'id goal)) "active"))
     (chat-session-save chat-tool-caller-current-session)
     (let* ((loaded (chat-session-load session-id))
            (work (chat-work--normalize-json
                   (cdr (assoc 'work (chat-session-metadata loaded))))))
       (should (string= (cdr (assoc 'title (cdr (assoc 'plan work))))
                        "Investigate"))
       (should (string= (cdr (assoc 'status (car (cdr (assoc 'todos work)))))
                        "done"))
       (should (string= (cdr (assoc 'status (car (cdr (assoc 'goals work)))))
                        "active"))))))

(ert-deftest chat-work-workflow-records-are-declarative-and-cancellable ()
  "Test workflow records store JSON steps without evaluating Lisp."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (chat-tool-caller-current-session
           (chat-session-create "Workflow" 'kimi)))
     (let* ((workflow (chat-work-workflow-start
                       "Draft"
                       "[{\"kind\":\"approval\",\"message\":\"Continue?\"}]"))
            (id (cdr (assoc 'id workflow)))
            (cancelled (chat-work-workflow-cancel id)))
       (should (string= (cdr (assoc 'status workflow))
                        "awaiting-approval"))
       (should (string= (cdr (assoc 'status cancelled)) "cancelled"))
       (should (equal (cdr (assoc 'kind (car (cdr (assoc 'steps workflow)))))
                      "approval"))))))

(ert-deftest chat-work-workflow-executes-ordered-conditional-tools ()
  "Test workflows execute tools in order and evaluate prior-step conditions."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (chat-tool-forge--registry (make-hash-table :test 'eq))
          (chat-tool-caller-current-session
           (chat-session-create "Workflow execution" 'kimi))
          calls)
     (chat-tool-forge-register
      (make-chat-forged-tool
       :id 'work_test_echo :name "Work Test Echo"
       :description "Echo a value."
       :language 'elisp :owner 'work :sensitivity 'public
       :effects '(read) :is-active t :usage-count 0
       :parameters '((:name "value" :type "string" :required t))
       :compiled-function
       (lambda (value)
         (setq calls (append calls (list value)))
         value)))
     (let* ((workflow
             (chat-work-workflow-start
              "Ordered"
              (concat
               "[{\"kind\":\"tool\",\"name\":\"work_test_echo\","
               "\"arguments\":{\"value\":\"hello\"}},"
               "{\"kind\":\"tool\",\"name\":\"work_test_echo\","
               "\"arguments\":{\"value\":\"world\"},"
               "\"when\":{\"step\":0,\"status\":\"succeeded\","
               "\"contains\":\"hell\"}}]")))
            (results (cdr (assoc 'results workflow))))
       (should (equal calls '("hello" "world")))
       (should (equal (cdr (assoc 'status workflow)) "completed"))
       (should (equal (mapcar (lambda (result)
                                (cdr (assoc 'status result)))
                              results)
                      '("succeeded" "succeeded")))))))

(ert-deftest chat-work-workflow-resumes-after-approval-checkpoint ()
  "Test approval checkpoints persist and resume at the following step."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (chat-tool-forge--registry (make-hash-table :test 'eq))
          (chat-tool-caller-current-session
           (chat-session-create "Workflow approval" 'kimi))
          called)
     (chat-tool-forge-register
      (make-chat-forged-tool
       :id 'work_test_finish :name "Work Test Finish"
       :description "Finish a test workflow."
       :language 'elisp :owner 'work :sensitivity 'public
       :effects '(read) :is-active t :usage-count 0 :parameters nil
       :compiled-function (lambda () (setq called t) "done")))
     (let* ((workflow
             (chat-work-workflow-start
              "Approval"
              (concat
               "[{\"kind\":\"approval\",\"message\":\"Proceed?\"},"
               "{\"kind\":\"tool\",\"name\":\"work_test_finish\"}]")))
            (id (cdr (assoc 'id workflow))))
       (should (equal (cdr (assoc 'status workflow))
                      "awaiting-approval"))
       (chat-session-save chat-tool-caller-current-session)
       (setq chat-tool-caller-current-session
             (chat-session-load
              (chat-session-id chat-tool-caller-current-session)))
       (let ((completed (chat-work-workflow-resume id "approve")))
         (should called)
         (should (equal (cdr (assoc 'status completed)) "completed"))
         (should (= (cdr (assoc 'stepIndex completed)) 2)))))))

(ert-deftest chat-work-workflow-pauses-on-tool-error-and-can-resume ()
  "Test a failed tool step remains resumable from the same index."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (chat-tool-forge--registry (make-hash-table :test 'eq))
          (chat-tool-caller-current-session
           (chat-session-create "Workflow retry" 'kimi)))
     (chat-tool-forge-register
      (make-chat-forged-tool
       :id 'work_test_retry :name "Work Test Retry"
       :description "Fail before replacement."
       :language 'elisp :owner 'work :sensitivity 'public
       :effects '(read) :is-active t :usage-count 0 :parameters nil
       :async-function
       (lambda (_argv _success error-callback)
         (funcall error-callback "temporary failure")
         nil)))
     (let* ((workflow
             (chat-work-workflow-start
              "Retry"
              "[{\"kind\":\"tool\",\"name\":\"work_test_retry\"}]"))
            (id (cdr (assoc 'id workflow))))
       (should (equal (cdr (assoc 'status workflow)) "paused"))
       (should (= (cdr (assoc 'stepIndex workflow)) 0))
       (setf (chat-forged-tool-async-function
              (chat-tool-forge-get 'work_test_retry))
             (lambda (_argv success _error-callback)
               (funcall success "recovered")
               nil))
       (let ((completed (chat-work-workflow-resume id)))
         (should (equal (cdr (assoc 'status completed)) "completed"))
         (should (equal (cdr (assoc 'result
                                    (car (cdr (assoc 'results completed)))))
                        "recovered")))))))

(ert-deftest chat-work-register-tools-adds-work-capabilities ()
  "Test work orchestration tools register with metadata."
  (let ((chat-tool-forge--registry (make-hash-table :test 'eq)))
    (chat-work-register-tools)
    (let ((tool (chat-tool-forge-get 'work_task_start)))
      (should tool)
      (should (eq (chat-forged-tool-owner tool) 'work))
      (should (memq 'outbound (chat-forged-tool-effects tool))))))

(provide 'test-chat-work)
;;; test-chat-work.el ends here
