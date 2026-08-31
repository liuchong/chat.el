;;; test-chat-work-platform-e2e.el --- Work platform agent paths -*- lexical-binding: t -*-

(require 'ert)
(require 'test-helper)
(require 'chat-agent)
(require 'chat-mcp)
(require 'chat-subagent)
(require 'chat-work)

(defun chat-e2e--transport (responses requests)
  "Return an async transport serving RESPONSES and recording REQUESTS."
  (let ((remaining responses))
    (lambda (_model messages success _error _options)
      (setcar requests (append (car requests) (list messages)))
      (funcall success (pop remaining))
      'e2e-handle)))

(defun chat-e2e--user-message (content)
  "Create one user message with CONTENT."
  (make-chat-message
   :id (chat-session-new-message-id "e2e-user")
   :role :user :content content :timestamp (current-time)))

(ert-deftest chat-e2e-agent-discovers-remote-result-and-finishes ()
  "Test a primary run calls a discovered MCP tool and synthesizes an answer."
  (let* ((chat-tool-forge--registry (make-hash-table :test 'eq))
         (chat-approval-noninteractive-policy 'approve)
         (client (chat-mcp-client-create :id "demo" :transport 'http))
         (session (make-chat-session :id "e2e-mcp" :model-id 'kimi))
         (requests (list nil))
         events)
    (chat-mcp--register-remote-tool
     client
     '((name . "echo")
       (description . "Echo")
       (inputSchema
        (type . "object")
        (properties (text (type . "string")))
        (required . ["text"]))
       (annotations (readOnlyHint . t))))
    (cl-letf
        (((symbol-function 'chat-mcp-call-tool-async)
          (lambda (_client _name arguments success _error)
            (funcall success
                     `((jsonrpc . "2.0") (id . "1")
                       (result
                        (content . ,(cdr (assoc "text" arguments))))))
            '(:cancel ignore)))
         ((symbol-function 'chat-llm-request-async)
          (chat-e2e--transport
           (list
            '(:content
              "{\"function_call\":{\"name\":\"mcp_demo_echo\",\"arguments\":{\"text\":\"remote-ok\"}}}")
            '(:content "Remote result received"))
           requests)))
      (chat-agent-start
       (list :provider 'kimi
             :session session
             :messages (list (chat-e2e--user-message "Use the remote tool"))
             :on-event (lambda (event) (push event events)))))
    (let ((end (car events)))
      (should (eq (plist-get end :type) 'agent-end))
      (should (eq (plist-get end :status) 'completed))
      (should (equal (plist-get end :content)
                     "Remote result received"))
      (should (string-match-p
               "remote-ok" (car (plist-get end :tool-results)))))
    (should (= (length (car requests)) 2))))

(ert-deftest chat-e2e-agent-runs-isolated-subagent-and-finishes ()
  "Test a primary run receives a nested agent summary through tool lifecycle."
  (let* ((chat-tool-forge--registry (make-hash-table :test 'eq))
         (chat-approval-noninteractive-policy 'approve)
         (session (make-chat-session :id "e2e-subagent" :model-id 'kimi))
         (requests (list nil))
         events)
    (chat-subagent-register-tools)
    (cl-letf
        (((symbol-function 'chat-subagent-start-agent)
          (lambda (_name _prompt _session success _error _budget)
            (funcall success
                     '((id . "child-1")
                       (status . "completed")
                       (summary . "nested-ok")))
            '(:cancel ignore)))
         ((symbol-function 'chat-llm-request-async)
          (chat-e2e--transport
           (list
            '(:content
              "{\"function_call\":{\"name\":\"subagent_run\",\"arguments\":{\"name\":\"Child\",\"prompt\":\"Investigate\",\"budget\":2}}}")
            '(:content "Nested result received"))
           requests)))
      (chat-agent-start
       (list :provider 'kimi
             :session session
             :messages (list (chat-e2e--user-message "Delegate this"))
             :on-event (lambda (event) (push event events)))))
    (let ((end (car events)))
      (should (eq (plist-get end :status) 'completed))
      (should (string-match-p
               "nested-ok" (car (plist-get end :tool-results)))))
    (should (= (length (car requests)) 2))))

(ert-deftest chat-e2e-agent-starts-and-observes-background-work ()
  "An Agent starts work, continues, reads output, and finishes from evidence."
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
          (session (make-chat-session :id "e2e-background" :model-id 'kimi))
          (other (make-chat-session :id "e2e-background-other" :model-id 'kimi))
          (requests (list nil))
          (request-number 0)
          task-id observed-output finished events)
     (chat-work-register-tools)
     (let ((chat-work-task-finished-hook
            (list (lambda (task)
                    (push (chat-work-task-id task) finished)))))
       (cl-letf
           (((symbol-function 'chat-llm-request-async)
             (lambda (_model messages success _error _options)
               (setcar requests (append (car requests) (list messages)))
               (setq request-number (1+ request-number))
               (pcase request-number
                 (1
                  (funcall
                   success
                   (list
                    :content
                    (json-encode
                     '((function_call
                        (name . "work_task_start")
                        (arguments
                         (command . "sleep 0.05; printf e2e-background"))))))))
                 (2
                  (let* ((summary (car (chat-work-task-list)))
                         (id (alist-get 'id summary))
                         (task (gethash id chat-work--tasks))
                         (deadline (+ (float-time) 3)))
                    (setq task-id id)
                    (while (and (not (memq (chat-work-task-status task)
                                           '(succeeded failed cancelled)))
                                (< (float-time) deadline))
                      (accept-process-output
                       (chat-work-task-process task) 0.05))
                    (funcall
                     success
                     (list
                      :content
                      (json-encode
                       `((function_call
                          (name . "work_task_output")
                          (arguments (id . ,id)))))))))
                 (3
                  (setq observed-output
                        (seq-some
                         (lambda (message)
                           (string-match-p
                            "e2e-background"
                            (or (chat-message-content message) "")))
                         messages))
                  (funcall success '(:content "Background output observed")))
                 (_ (error "Unexpected model request %s" request-number)))
               (list :cancel #'ignore))))
         (chat-agent-start
          (list :provider 'kimi
                :session session
                :messages
                (list (chat-e2e--user-message
                       "Run the background check and report its output"))
                :on-event (lambda (event) (push event events)))))
       (let ((end (car events)))
         (should (eq (plist-get end :type) 'agent-end))
         (should (eq (plist-get end :status) 'completed))
         (should (equal (plist-get end :content)
                        "Background output observed")))
       (should (= (length (car requests)) 3))
       (should task-id)
       (should observed-output)
       (should (equal finished (list task-id)))
       (should (eq (chat-task-status (chat-task-get task-id)) 'completed))
       (let ((chat-tool-caller-current-session other))
         (should-error (chat-work-task-output task-id) :type 'error))))))

(provide 'test-chat-work-platform-e2e)
;;; test-chat-work-platform-e2e.el ends here
