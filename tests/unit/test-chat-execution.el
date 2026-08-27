;;; test-chat-execution.el --- Execution backend contract tests -*- lexical-binding: t -*-

(require 'ert)
(require 'test-helper)
(require 'chat-execution)

(defun chat-execution-test--wait (record)
  "Wait for local execution RECORD to finish."
  (let ((process (chat-execution-native-handle record)))
    (while (and process (process-live-p process))
      (accept-process-output process 0.05)))
  record)

(ert-deftest chat-execution-local-attempt-is-durable-and-correlated ()
  "A local attempt records identity without persisting environment values."
  (chat-test-with-temp-dir
   (let ((chat-execution-directory (expand-file-name "executions/" chat-state-dir))
         (chat-execution--records (make-hash-table :test 'equal))
         (chat-execution--backends (make-hash-table :test 'eq)))
     (chat-execution-install-local-backend)
     (let* ((request
             (chat-execution-request-create
              :command (list shell-file-name shell-command-switch "printf ok")
              :directory temp-dir
              :environment '("VISIBLE_NAME=secret-value")
              :session-id "session-execution"
              :turn-id 7
              :task-id "task-execution"
              :idempotency 'read-only))
            (record (chat-execution-start request :name "test-execution")))
       (chat-execution-test--wait record)
       (should (eq (chat-execution-record-status record) 'completed))
       (should (= (length (chat-execution-record-attempts record)) 1))
       (should (= (plist-get (car (chat-execution-record-attempts record))
                             :exit-code)
                  0))
       (with-temp-buffer
         (insert-file-contents (chat-execution--state-file))
         (should (search-forward "VISIBLE_NAME" nil t))
         (should-not (search-forward "secret-value" nil t)))))))

(ert-deftest chat-execution-restart-interrupts-without-starting-anything ()
  "Loading a running attempt records interruption and creates no process."
  (chat-test-with-temp-dir
   (let ((chat-execution-directory (expand-file-name "executions/" chat-state-dir))
         (chat-execution--records (make-hash-table :test 'equal))
         (chat-execution--backends (make-hash-table :test 'eq)))
     (chat-execution-install-local-backend)
     (let* ((request (chat-execution-request-create
                      :id "execution-stale"
                      :command '("printf" "never")
                      :directory temp-dir
                      :idempotency 'idempotent))
            (record (chat-execution-record-create
                     :id "execution-stale"
                     :request request
                     :status 'running
                     :created-at 1
                     :updated-at 1
                     :attempts (list (list :number 1 :status 'running
                                          :started-at 1)))))
       (puthash "execution-stale" record chat-execution--records)
       (chat-execution-save)
       (clrhash chat-execution--records)
       (let ((started nil))
         (cl-letf (((symbol-function 'make-process)
                    (lambda (&rest _args)
                      (setq started t)
                      (error "must not start"))))
           (should (= (chat-execution-load) 1)))
         (should-not started))
       (let ((loaded (chat-execution-get "execution-stale")))
         (should (eq (chat-execution-record-status loaded) 'interrupted))
         (should (eq (plist-get (car (chat-execution-record-attempts loaded))
                                :status)
                     'interrupted))
         (should-not (chat-execution-record-native-handle loaded)))))))

(ert-deftest chat-execution-non-idempotent-retry-needs-renewed-permission ()
  "A completed external effect cannot be repeated by a bare retry."
  (chat-test-with-temp-dir
   (let ((chat-execution-directory (expand-file-name "executions/" chat-state-dir))
         (chat-execution--records (make-hash-table :test 'equal))
         (chat-execution--backends (make-hash-table :test 'eq)))
     (chat-execution-install-local-backend)
     (let* ((request
             (chat-execution-request-create
              :command (list shell-file-name shell-command-switch "exit 0")
              :directory temp-dir
              :idempotency 'non-idempotent))
            (record (chat-execution-start request)))
       (chat-execution-test--wait record)
       (should-error (chat-execution-retry record)
                     :type 'chat-execution-renewal-required)
       (chat-execution-retry record :renewed-permission t)
       (chat-execution-test--wait record)
       (should (eq (chat-execution-record-status record) 'completed))
       (should (= (length (chat-execution-record-attempts record)) 2))))))

(ert-deftest chat-execution-cancel-wins-over-the-process-sentinel ()
  "Cancellation remains canceled even when deleting the process runs sentinel."
  (chat-test-with-temp-dir
   (let ((chat-execution-directory (expand-file-name "executions/" chat-state-dir))
         (chat-execution--records (make-hash-table :test 'equal))
         (chat-execution--backends (make-hash-table :test 'eq)))
     (chat-execution-install-local-backend)
     (let ((record
            (chat-execution-start
             (chat-execution-request-create
              :command (list shell-file-name shell-command-switch "sleep 5")
              :directory temp-dir
              :idempotency 'idempotent))))
       (should (chat-execution-live-p record))
       (chat-execution-cancel record "test cancellation")
       (should (eq (chat-execution-record-status record) 'canceled))
       (should-not (chat-execution-live-p record))))))

(ert-deftest chat-execution-task-adapters-have-no-private-process-creation ()
  "Task adapters route process creation through the execution backend."
  (dolist (file '("lisp/tools/chat-tool-shell.el"
                  "lisp/tools/chat-work.el"
                  "lisp/tools/chat-subagent.el"
                  "lisp/tools/chat-mcp.el"
                  "lisp/code/chat-code-test.el"))
    (with-temp-buffer
      (insert-file-contents file)
      (should-not (re-search-forward "(make-process\\_>" nil t)))))

(provide 'test-chat-execution)
;;; test-chat-execution.el ends here
