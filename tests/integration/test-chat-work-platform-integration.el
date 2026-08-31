;;; test-chat-work-platform-integration.el --- Cross-module work tests -*- lexical-binding: t -*-

(require 'ert)
(require 'test-helper)
(require 'chat-mcp)
(require 'chat-tool-caller)
(require 'chat-work)

(ert-deftest chat-integration-workflow-runs-discovered-mcp-tool-durably ()
  "Test workflow, MCP, tool-caller, approval, and session persistence together."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (chat-tool-forge--registry (make-hash-table :test 'eq))
          (chat-approval-noninteractive-policy 'approve)
          (chat-tool-caller-current-session
           (chat-session-create "Integrated workflow" 'kimi))
          (client (chat-mcp-client-create :id "demo" :transport 'http)))
     (chat-mcp--register-remote-tool
      client
      '((name . "echo")
        (description . "Echo a value")
        (inputSchema
         (type . "object")
         (properties (value (type . "string")))
         (required . ["value"]))
        (annotations (readOnlyHint . t))))
     (cl-letf (((symbol-function 'chat-mcp-call-tool-async)
                (lambda (_client _name arguments success _error)
                  (funcall
                   success
                   `((jsonrpc . "2.0") (id . "1")
                     (result
                      (content . ,(cdr (assoc "value" arguments))))))
                  '(:cancel ignore))))
       (let* ((workflow
               (chat-work-workflow-start
                "Remote workflow"
                (concat
                 "[{\"kind\":\"tool\",\"name\":\"mcp_demo_echo\","
                 "\"arguments\":{\"value\":\"integrated\"}}]")))
              (workflow-id (cdr (assoc 'id workflow)))
              (session-id
               (chat-session-id chat-tool-caller-current-session)))
         (should (equal (cdr (assoc 'status workflow)) "completed"))
         (should (string-match-p
                  "integrated"
                  (cdr (assoc 'result
                              (car (cdr (assoc 'results workflow)))))))
         (chat-session-save chat-tool-caller-current-session)
         (setq chat-tool-caller-current-session
               (chat-session-load session-id))
         (let ((reloaded
                (cl-find
                 workflow-id
                 (chat-work-workflow-list)
                 :key (lambda (entry) (cdr (assoc 'id entry)))
                 :test #'equal)))
           (should (equal (cdr (assoc 'status reloaded))
                          "completed"))))))))

(ert-deftest chat-integration-background-task-is-observable-and-session-scoped ()
  "A tool-started process completes by callback without crossing sessions."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory (expand-file-name "sessions/" temp-dir))
          (chat-work-directory (expand-file-name "work/" temp-dir))
          (chat-task-directory (expand-file-name "runtime/" temp-dir))
          (chat-execution-directory (expand-file-name "execution/" temp-dir))
          (chat-tool-forge--registry (make-hash-table :test 'eq))
          (chat-work--tasks (make-hash-table :test 'equal))
          (chat-task--registry (make-hash-table :test 'equal))
          (chat-task--loaded-p t)
          (chat-task--scheduling-p nil)
          (chat-execution--records (make-hash-table :test 'equal))
          (chat-session-wire--sequences (make-hash-table :test 'equal))
          (chat-session-wire--sizes (make-hash-table :test 'equal))
          (chat-session-wire-enabled t)
          (chat-approval-noninteractive-policy 'approve)
          (chat-work-notify-task-completion nil)
          (owner (make-chat-session :id "background-owner" :name "Owner"))
          (other (make-chat-session :id "background-other" :name "Other"))
          finished tool-result tool-error observer-events)
     (chat-work-register-tools)
     (let ((chat-work-task-finished-hook
            (list (lambda (task)
                    (push (chat-work-task-id task) finished)))))
       (let ((handle
              (chat-tool-caller-execute-async
               '(:name "work_task_start"
                 :arguments (("command" . "sleep 0.05; printf integration-ok")))
               owner
               (lambda (event) (push event observer-events))
               (lambda (value) (setq tool-result value))
               (lambda (message) (setq tool-error message)))))
         (should handle)
         (should tool-result)
         (should-not tool-error))
       (let* ((summary (car (chat-work-task-list)))
              (id (alist-get 'id summary))
              (task (gethash id chat-work--tasks))
              (deadline (+ (float-time) 3)))
         (should id)
         (while (and (not (memq (chat-work-task-status task)
                                '(succeeded failed cancelled)))
                     (< (float-time) deadline))
           (accept-process-output (chat-work-task-process task) 0.05))
         (should (eq (chat-work-task-status task) 'succeeded))
         (should (equal finished (list id)))
         (let ((chat-tool-caller-current-session owner))
           (let ((output (chat-work-task-output id)))
             (should (equal (alist-get 'status output) "succeeded"))
             (should (eq (alist-get 'terminal output) t))
             (should (equal (alist-get 'output output) "integration-ok"))))
         (let ((chat-tool-caller-current-session other))
           (should-error (chat-work-task-output id) :type 'error))
         (let* ((wire (chat-session-wire-read "background-owner"))
                (kinds (mapcar (lambda (record) (alist-get 'kind record))
                               wire)))
           (should (equal kinds
                          '("permission-requested" "permission-resolved"
                            "task-started" "execution-started"
                            "execution-ended" "task-ended")))
           (should (cl-every
                    (lambda (record)
                      (equal id (alist-get 'task_id record)))
                    (seq-filter
                     (lambda (record)
                       (member (alist-get 'kind record)
                               '("task-started" "execution-started"
                                 "execution-ended" "task-ended")))
                     wire))))
         (should (seq-some
                  (lambda (event)
                    (eq (plist-get event :type) 'tool-result))
                  observer-events)))))))

(provide 'test-chat-work-platform-integration)
;;; test-chat-work-platform-integration.el ends here
