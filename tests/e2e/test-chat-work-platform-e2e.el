;;; test-chat-work-platform-e2e.el --- Work platform agent paths -*- lexical-binding: t -*-

(require 'ert)
(require 'test-helper)
(require 'chat-agent)
(require 'chat-mcp)
(require 'chat-subagent)

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
       (list :model 'kimi
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
       (list :model 'kimi
             :session session
             :messages (list (chat-e2e--user-message "Delegate this"))
             :on-event (lambda (event) (push event events)))))
    (let ((end (car events)))
      (should (eq (plist-get end :status) 'completed))
      (should (string-match-p
               "nested-ok" (car (plist-get end :tool-results)))))
    (should (= (length (car requests)) 2))))

(provide 'test-chat-work-platform-e2e)
;;; test-chat-work-platform-e2e.el ends here
