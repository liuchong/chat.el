;;; test-chat-mcp-subagent.el --- Tests for MCP and sub-agents -*- lexical-binding: t -*-

(require 'ert)
(require 'test-helper)
(require 'chat-mcp)
(require 'chat-subagent)

(ert-deftest chat-mcp-records-json-rpc-responses-by-id ()
  "Test JSON-RPC response handling stores responses by id."
  (let ((client (chat-mcp-client-create :transport 'stdio)))
    (chat-mcp--handle-line
     client
     "{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"result\":{\"ok\":true}}")
    (should (equal (cdr (assoc 'result
                               (gethash "1"
                                        (chat-mcp-client-responses client))))
                   '((ok . t))))))

(ert-deftest chat-mcp-stdio-client-can_roundtrip_against_echo_process ()
  "Test stdio client lifecycle against an echo process."
  (let ((client (chat-mcp-client-create
                 :transport 'stdio
                 :command '("cat"))))
    (unwind-protect
        (progn
          (chat-mcp-stdio-start client)
          (let ((response (chat-mcp-stdio-request
                           client "tools/list" nil 2)))
            (should (string= (cdr (assoc 'method response))
                             "tools/list")))
          (chat-mcp-cancel client "1")
          (should (eq (chat-mcp-client-status client) 'running)))
      (chat-mcp-stop client))
    (should (eq (chat-mcp-client-status client) 'stopped))))

(ert-deftest chat-mcp-http-request-decodes-json-response ()
  "Test HTTP JSON-RPC request decoding with a mocked transport."
  (cl-letf (((symbol-function 'url-retrieve-synchronously)
             (lambda (&rest _args)
               (let ((buffer (generate-new-buffer " *mcp-http*")))
                 (with-current-buffer buffer
                   (insert "HTTP/1.1 200 OK\r\n\r\n")
                   (insert "{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"result\":{\"tools\":[]}}"))
                 buffer))))
    (let ((response (chat-mcp-http-request "http://example.invalid" "tools/list")))
      (should (equal (cdr (assoc 'result response))
                     '((tools)))))))

(ert-deftest chat-subagent-in-process-uses-isolated-child-session ()
  "Test in-process sub-agents keep child state isolated."
  (let* ((parent (make-chat-session :id "parent" :name "Parent"
                                    :model-id 'kimi))
         (message (make-chat-message :id "u1" :role :user
                                     :content "hello"))
         (subagent
          (chat-subagent-start-in-process
           "Child"
           (list message)
           (lambda (child-session)
             (format "messages:%d"
                     (length (chat-session-messages child-session))))
           parent
           1)))
    (should (eq (chat-subagent-status subagent) 'completed))
    (should (string= (chat-subagent-summary subagent) "messages:1"))
    (should (string= (chat-session-parent-session-id
                      (chat-subagent-child-session subagent))
                     "parent"))))

(ert-deftest chat-subagent-external-captures-output ()
  "Test external sub-agent backend captures subprocess output."
  (chat-test-with-temp-dir
   (let* ((log-file (expand-file-name "subagent.log" temp-dir))
          (subagent
           (chat-subagent-start-external
            "External"
            (list shell-file-name shell-command-switch "printf external-ok")
            nil
            log-file)))
     (while (process-live-p (chat-subagent-process subagent))
       (accept-process-output (chat-subagent-process subagent) 0.1))
     (should (eq (chat-subagent-status subagent) 'completed))
     (should (string= (chat-subagent-external-output
                       (chat-subagent-id subagent))
                      "external-ok")))))

(provide 'test-chat-mcp-subagent)
;;; test-chat-mcp-subagent.el ends here
