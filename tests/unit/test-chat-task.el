;;; test-chat-task.el --- Durable task contract tests -*- lexical-binding: t -*-

(require 'ert)
(require 'test-helper)
(require 'chat-task)

(defmacro chat-task-test--isolated (&rest body)
  "Run BODY with an isolated durable task registry."
  `(chat-test-with-temp-dir
    (let ((chat-task-directory temp-dir)
          (chat-task--registry (make-hash-table :test 'equal))
          (chat-task--loaded-p t)
          (chat-task--scheduling-p nil)
          (chat-task-auto-save t)
          (chat-task-max-parallel 4)
          (chat-event-observer-functions nil)
          (chat-event-blocker-functions nil))
      ,@body)))

(defun chat-task-test--task (id &rest fields)
  "Return queued test task ID with FIELDS."
  (apply #'chat-task-create :id id :kind 'test :title id fields))

(ert-deftest chat-task-terminal-state-is-idempotent-and-exclusive ()
  "One task emits one terminal state and cannot change its ending."
  (chat-task-test--isolated
   (let ((task (chat-task-register (chat-task-test--task "one"))))
     (chat-task-transition task 'running)
     (chat-task-transition task 'completed :result "done")
     (should (eq (chat-task-status task) 'completed))
     (should (eq (chat-task-status
                  (chat-task-transition task 'completed :result "done"))
                 'completed))
     (should-error (chat-task-transition task 'failed :error "late")
                   :type 'chat-task-terminal-conflict))))

(ert-deftest chat-task-same-state-checkpoint-is-an-observable-update ()
  "Updating live task data advances its timestamp and emits an update."
  (chat-task-test--isolated
   (let ((task (chat-task-register (chat-task-test--task "updating")))
         events)
     (chat-task-transition task 'running)
     (setf (chat-task-updated-at task) "before")
     (chat-event-add-observer (lambda (event) (push event events)))
     (chat-task-transition task 'running
                           :checkpoint '((stepIndex . 2)))
     (should-not (equal (chat-task-updated-at task) "before"))
     (should (equal (chat-task-checkpoint task) '((stepIndex . 2))))
     (should (equal (mapcar #'chat-event-type events) '(task-updated))))))

(ert-deftest chat-task-cancellation-token-runs-callbacks-once ()
  "Cancellation callbacks observe one stable reason exactly once."
  (let ((token (chat-cancellation-token-create :id "token"))
        calls)
    (chat-cancellation-token-add-callback
     token (lambda (reason) (push reason calls)))
    (chat-cancellation-token-cancel token "stop")
    (chat-cancellation-token-cancel token "again")
    (should (equal calls '("stop")))
    (should (equal (chat-cancellation-token-reason token) "stop"))))

(ert-deftest chat-task-scheduler-parallelizes-reads-and-serializes-writes ()
  "Resource conflicts hold writers while independent readers can run."
  (chat-task-test--isolated
   (let ((callbacks (make-hash-table :test 'equal))
         started)
     (dolist (entry '(("read-a" read) ("read-b" read) ("write" write)))
       (chat-task-submit
        (chat-task-test--task
         (car entry)
         :resources (list (list :key "repo" :mode (cadr entry))))
        (lambda (task complete _fail _attention)
          (push (chat-task-id task) started)
          (puthash (chat-task-id task) complete callbacks)
          :async)))
     (should (equal (sort (copy-sequence started) #'string<)
                    '("read-a" "read-b")))
     (should (eq (chat-task-status (chat-task-get "write")) 'queued))
     (funcall (gethash "read-a" callbacks) "a")
     (should (eq (chat-task-status (chat-task-get "write")) 'queued))
     (funcall (gethash "read-b" callbacks) "b")
     (should (eq (chat-task-status (chat-task-get "write")) 'running)))))

(ert-deftest chat-task-parent-cancellation-cascades-by-policy ()
  "Cancel policy reaches active children and stays idempotent."
  (chat-task-test--isolated
   (let ((parent (chat-task-register
                  (chat-task-test--task "parent" :child-policy 'cancel))))
     (chat-task-register
      (chat-task-test--task "child" :parent-id "parent"))
     (chat-task-cancel "parent" "stop tree")
     (should (eq (chat-task-status parent) 'canceled))
     (should (eq (chat-task-status (chat-task-get "child")) 'canceled))
     (should (eq (chat-task-status (chat-task-cancel "parent")) 'canceled)))))

(ert-deftest chat-task-round-trip-interrupts-stale-running-work ()
  "Durable loading keeps intent but never resurrects a live runner."
  (chat-task-test--isolated
   (let ((task (chat-task-register (chat-task-test--task "durable"))))
     (chat-task-transition task 'running)
     (setq chat-task--registry (make-hash-table :test 'equal)
           chat-task--loaded-p nil)
     (chat-task-load)
     (let ((loaded (chat-task-get "durable")))
       (should (eq (chat-task-status loaded) 'interrupted))
       (should-not (chat-task-runner loaded))
       (let ((file (expand-file-name "tasks.json" temp-dir)))
         (should (file-exists-p file))
         (with-temp-buffer
           (insert-file-contents file)
           (should (string-match-p "\"status\":\"interrupted\""
                                   (buffer-string)))))))))

(ert-deftest chat-task-refuses-future-registry-without-rewriting-it ()
  "Future task schemas fail closed and leave their source untouched."
  (chat-task-test--isolated
   (let ((file (expand-file-name "tasks.json" temp-dir)))
     (with-temp-file file
       (insert "{\"schemaVersion\":999,\"tasks\":[]}"))
     (setq chat-task--loaded-p nil)
     (should-error (chat-task-load) :type 'chat-task-unsupported-schema)
     (with-temp-buffer
       (insert-file-contents file)
       (should (string-match-p "999" (buffer-string)))))))

(provide 'test-chat-task)
;;; test-chat-task.el ends here
