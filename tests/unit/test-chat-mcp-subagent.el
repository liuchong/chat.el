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

(ert-deftest chat-mcp-streamable-http-keeps-session-and-decodes-sse ()
  "Test Streamable HTTP records session ids and accepts SSE responses."
  (let ((client (chat-mcp-client-create
                 :transport 'http
                 :endpoint "http://example.invalid/mcp")))
    (cl-letf (((symbol-function 'url-retrieve-synchronously)
               (lambda (&rest _args)
                 (let ((buffer (generate-new-buffer " *mcp-sse*")))
                   (with-current-buffer buffer
                     (insert "HTTP/1.1 200 OK\r\n")
                     (insert "Mcp-Session-Id: session-42\r\n\r\n")
                     (insert "event: message\n")
                     (insert "data: {\"jsonrpc\":\"2.0\",\"id\":\"1\",")
                     (insert "\"result\":{\"tools\":[]}}\n\n"))
                   buffer))))
      (let ((response
             (chat-mcp-http-client-request client "tools/list")))
        (should (equal (chat-mcp-client-session-id client)
                       "session-42"))
        (should (equal (cdr (assoc 'result response))
                       '((tools))))))))

(ert-deftest chat-mcp-configured-server-registers-schema-aware-tools ()
  "Test discovery turns configured remote capabilities into forged tools."
  (let ((chat-mcp-servers
         '((:id "notes" :transport http
            :endpoint "http://example.invalid/mcp")))
        (chat-mcp--clients (make-hash-table :test 'equal))
        (chat-tool-forge--registry (make-hash-table :test 'eq)))
    (chat-mcp-configure-servers)
    (chat-mcp-register-tools)
    (cl-letf (((symbol-function 'chat-mcp-initialize)
               (lambda (_client)
                 '((jsonrpc . "2.0") (id . "1") (result))))
              ((symbol-function 'chat-mcp-list-tools)
               (lambda (_client)
                 '((jsonrpc . "2.0")
                   (id . "2")
                   (result
                    (tools
                     ((name . "lookup")
                      (description . "Look up a note")
                      (inputSchema
                       (type . "object")
                       (properties
                        (query (type . "string")
                               (enum . ["title" "body"])))
                       (required . ["query"]))
                      (annotations (readOnlyHint . t)))))))))
      (let* ((summary (chat-mcp-connect-server "notes"))
             (tool (chat-tool-forge-get 'mcp_notes_lookup))
             (parameter (car (chat-forged-tool-parameters tool))))
        (should (equal (cdr (assoc 'status summary)) "ready"))
        (should tool)
        (should (equal (plist-get parameter :name) "query"))
        (should (plist-get parameter :required))
        (should (equal (plist-get parameter :enum)
                       '("title" "body")))
        (should (equal (chat-forged-tool-effects tool)
                       '(read outbound)))))))

(ert-deftest chat-mcp-connect-tool-discovers-without-blocking ()
  "Test the connect tool chains initialize and discovery asynchronously."
  (let* ((client (chat-mcp-client-create
                  :id "async" :transport 'http
                  :endpoint "http://example.invalid/mcp"))
         (chat-mcp--clients (make-hash-table :test 'equal))
         (chat-tool-forge--registry (make-hash-table :test 'eq))
         methods
         result)
    (puthash "async" client chat-mcp--clients)
    (cl-letf (((symbol-function 'chat-mcp-request-async)
               (lambda (_client method _params success _error &optional _timeout)
                 (push method methods)
                 (funcall
                  success
                  (if (equal method "initialize")
                      '((jsonrpc . "2.0") (id . "1")
                        (result (protocolVersion . "2024-11-05")))
                    '((jsonrpc . "2.0") (id . "2")
                      (result
                       (tools
                        ((name . "ping")
                         (inputSchema
                          (type . "object")
                          (properties))))))))
                 '(:cancel ignore)))
              ((symbol-function 'chat-mcp-send-notification-async)
               (lambda (_client method _params success _error)
                 (push method methods)
                 (funcall success t)
                 nil)))
      (chat-mcp-connect-server-async
       '("async")
       (lambda (value) (setq result value))
       #'ert-fail))
    (should (equal (reverse methods)
                   '("initialize" "notifications/initialized"
                     "tools/list")))
    (should (equal (cdr (assoc 'status result)) "ready"))
    (should (chat-tool-forge-get 'mcp_async_ping))))

(ert-deftest chat-mcp-async-response-dispatches-pending-callback ()
  "Test JSON-RPC responses complete their asynchronous pending request."
  (let* ((client (chat-mcp-client-create :transport 'stdio))
         value)
    (puthash "7" (list :success
                       (lambda (response)
                         (setq value (cdr (assoc 'result response))))
                       :error #'ignore)
             (chat-mcp-client-pending client))
    (chat-mcp--handle-line
     client
     "{\"jsonrpc\":\"2.0\",\"id\":\"7\",\"result\":{\"value\":42}}")
    (should (equal value '((value . 42))))
    (should-not (gethash "7" (chat-mcp-client-pending client)))))

(ert-deftest chat-mcp-discovered-tool-uses-async-remote-call ()
  "Test a discovered tool delegates through the cancellable async client."
  (let* ((client (chat-mcp-client-create :id "remote" :transport 'http))
         (chat-tool-forge--registry (make-hash-table :test 'eq))
         captured
         result)
    (chat-mcp--register-remote-tool
     client
     '((name . "echo")
       (description . "Echo")
       (inputSchema
        (type . "object")
        (properties (text (type . "string")))
        (required . ["text"]))))
    (cl-letf (((symbol-function 'chat-mcp-call-tool-async)
               (lambda (_client name arguments success _error)
                 (setq captured (list name arguments))
                 (funcall success
                          '((jsonrpc . "2.0")
                            (id . "1")
                            (result (content . "ok"))))
                 '(:cancel ignore))))
      (funcall
       (chat-forged-tool-async-function
        (chat-tool-forge-get 'mcp_remote_echo))
       '("hello")
       (lambda (value) (setq result value))
       #'ert-fail))
    (should (equal captured '("echo" (("text" . "hello")))))
    (should (string-match-p "ok" result))))

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
                     "parent"))
    (should (equal
             (cdr (assoc 'parentTaskId
                         (chat-session-metadata
                          (chat-subagent-child-session subagent))))
             (chat-subagent-id subagent)))
    (should (eq (chat-task-status
                 (chat-task-get (chat-subagent-id subagent)))
                'completed))))

(ert-deftest chat-subagent-lifecycle-is-recorded-on-the-parent-session ()
  "A child start and terminal outcome remain visible from its parent."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (chat-session-wire--sequences (make-hash-table :test 'equal))
          (chat-session-wire--sizes (make-hash-table :test 'equal))
          (chat-session-wire-enabled t)
          (parent (make-chat-session :id "subagent-wire" :name "Parent"
                                     :model-id 'kimi))
          (subagent
           (chat-subagent-start-in-process
            "Child" nil (lambda (_session) "done") parent 1))
          (records (chat-session-wire-read "subagent-wire"))
          (kinds (mapcar (lambda (record) (alist-get 'kind record)) records)))
     (should (equal kinds
                    '("task-started" "subagent-started"
                      "task-ended" "subagent-ended")))
     (should
      (cl-every
       (lambda (record)
         (equal (chat-subagent-id subagent) (alist-get 'task_id record)))
       records)))))

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

(ert-deftest chat-subagent-external-start-failure-closes-runtime-task ()
  "A subprocess creation error leaves a durable failed outcome."
  (chat-test-with-temp-dir
   (let ((chat-task-directory (expand-file-name "runtime/" temp-dir))
         (chat-task--registry (make-hash-table :test 'equal))
         (chat-task--loaded-p t)
         (chat-subagent--registry (make-hash-table :test 'equal))
         (id "external-failure"))
     (cl-letf (((symbol-function 'make-process)
                (lambda (&rest _args) (error "cannot start"))))
       (should-error
        (chat-subagent-start-external
         "External" '("missing") nil
         (expand-file-name "subagent.log" temp-dir)
         0 nil nil id)
        :type 'error))
     (should (eq (chat-subagent-status
                  (gethash id chat-subagent--registry))
                 'failed))
     (should (eq (chat-task-status (chat-task-get id)) 'failed))
     (should (equal (chat-task-error (chat-task-get id))
                    "cannot start")))))

(ert-deftest chat-subagent-nested-agent-returns-parent-safe-summary ()
  "Test the nested backend uses the kernel and returns only final content."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (chat-subagent--registry (make-hash-table :test 'equal))
          (parent (make-chat-session
                   :id "parent" :name "Parent" :model-id 'kimi
                   :metadata '((subagentDepth . 0))))
          summary)
     (cl-letf (((symbol-function 'chat-agent-start)
                (lambda (config)
                  (funcall
                   (plist-get config :on-event)
                   (list :type 'agent-end :status 'completed
                         :content "child summary" :step 1))
                  'fake-run)))
       (chat-subagent-start-agent
        "Research" "Find the answer" parent
        (lambda (value) (setq summary value))
        #'ert-fail 3))
     (should (equal (cdr (assoc 'summary summary)) "child summary"))
     (let ((subagent
            (car (hash-table-values chat-subagent--registry))))
       (should (= (chat-subagent-depth subagent) 1))
       (should (= (length
                   (chat-session-messages
                    (chat-subagent-child-session subagent)))
                  1))))))

(ert-deftest chat-subagent-registers-primary-loop-tools ()
  "Test nested and external backends are exposed as forged tools."
  (let ((chat-tool-forge--registry (make-hash-table :test 'eq)))
    (chat-subagent-register-tools)
    (let ((run (chat-tool-forge-get 'subagent_run))
          (external (chat-tool-forge-get 'subagent_external_start)))
      (should (chat-forged-tool-async-function run))
      (should (memq 'outbound (chat-forged-tool-effects run)))
      (should (eq (chat-forged-tool-sensitivity external)
                  'restricted)))))

(ert-deftest chat-subagent-tool-emits-standard-request-lifecycle-events ()
  "Test nested runs use the normal tool-call and tool-result event path."
  (let ((chat-tool-forge--registry (make-hash-table :test 'eq))
        (chat-approval-noninteractive-policy 'approve)
        (session (make-chat-session :id "parent" :model-id 'kimi))
        events
        result)
    (chat-subagent-register-tools)
    (cl-letf (((symbol-function 'chat-subagent-start-agent)
               (lambda (_name _prompt _session success _error _budget)
                 (funcall success
                          '((id . "child") (summary . "done")))
                 '(:cancel ignore))))
      (chat-tool-caller-execute-async
       (list :name "subagent_run"
             :arguments '(("name" . "Child")
                          ("prompt" . "Do work")
                          ("budget" . 2)))
       session
       (lambda (event) (push (plist-get event :type) events))
       (lambda (value) (setq result value))
       #'ert-fail))
    (should (string-match-p "done" result))
    (should (memq 'tool-call events))
    (should (memq 'tool-result events))))

(provide 'test-chat-mcp-subagent)
;;; test-chat-mcp-subagent.el ends here
