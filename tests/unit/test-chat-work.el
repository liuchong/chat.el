;;; test-chat-work.el --- Tests for chat-work.el -*- lexical-binding: t -*-

(require 'ert)
(require 'test-helper)
(require 'chat-work)

(ert-deftest chat-work-background-task-runs-and-captures-output ()
  "Test background tasks run asynchronously and keep bounded output."
  (chat-test-with-temp-dir
   (let ((chat-work-directory temp-dir)
         (chat-work--tasks (make-hash-table :test 'equal)))
     (let* ((summary (chat-work-task-start "printf hello" default-directory))
            (id (cdr (assoc 'id summary)))
            (task (gethash id chat-work--tasks)))
       (while (and (process-live-p (chat-work-task-process task)))
         (accept-process-output (chat-work-task-process task) 0.1))
       (should (eq (chat-work-task-status task) 'succeeded))
       (should (string= (chat-work-task-output id) "hello"))
       (should (file-exists-p (expand-file-name "tasks.json" temp-dir)))))))

(ert-deftest chat-work-background-task-stop-cancels-process ()
  "Test background task stop marks a running process cancelled."
  (chat-test-with-temp-dir
   (let ((chat-work-directory temp-dir)
         (chat-work--tasks (make-hash-table :test 'equal)))
     (let* ((summary (chat-work-task-start "sleep 5" default-directory))
            (id (cdr (assoc 'id summary)))
            (task (gethash id chat-work--tasks)))
       (should (process-live-p (chat-work-task-process task)))
       (chat-work-task-stop id)
       (should (eq (chat-work-task-status task) 'cancelled))))))

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
                       "[{\"kind\":\"tool\",\"name\":\"work_todo_list\"}]"))
            (id (cdr (assoc 'id workflow)))
            (cancelled (chat-work-workflow-cancel id)))
       (should (string= (cdr (assoc 'status workflow)) "running"))
       (should (string= (cdr (assoc 'status cancelled)) "cancelled"))
       (should (equal (cdr (assoc 'kind (car (cdr (assoc 'steps workflow)))))
                      "tool"))))))

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
