;;; test-chat-work-platform-integration.el --- Cross-module work tests -*- lexical-binding: t -*-

(require 'ert)
(require 'test-helper)
(require 'chat-mcp)
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

(provide 'test-chat-work-platform-integration)
;;; test-chat-work-platform-integration.el ends here
