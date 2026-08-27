;;; test-chat-termini-bridge.el --- Tests for Termini bridge -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'test-helper)
(require 'chat-termini-bridge)

(defun chat-termini-test--client ()
  "Return an isolated bridge client."
  (chat-termini-client-create :id "test" :command '("termini")))

(defun chat-termini-test--initialize-result (&optional methods version)
  "Return an initialization RESULT with METHODS and VERSION."
  `((serverInfo . ((name . "termini")
                   (protocolVersion . ,(or version "2026-07-08"))))
    (negotiatedProtocolVersion . ,(or version "2026-07-08"))
    (capabilities
     . ((methods . ,(or methods chat-termini-required-methods))
        (events . ("job/started" "job/completed" "job/failed"))))))

(ert-deftest chat-termini-request-ids-are-monotonic-json-rpc-numbers ()
  "Requests carry stable numeric correlation IDs."
  (let* ((client (chat-termini-test--client))
         (first (chat-termini--request client "session/list" nil))
         (second (chat-termini--request client "job/list" '((limit . 10)))))
    (should (= 1 (alist-get 'id first)))
    (should (= 2 (alist-get 'id second)))
    (should (equal "2.0" (alist-get 'jsonrpc first)))
    (should (equal "session/list" (alist-get 'method first)))
    (should (string-match-p
             "\\\"params\\\":{}" (json-encode first)))
    (should (equal '((limit . 10)) (alist-get 'params second)))))

(ert-deftest chat-termini-filter-handles-split-coalesced-and-blank-lines ()
  "Arbitrary process chunks still produce complete messages in order."
  (let ((client (chat-termini-test--client)))
    (puthash 1 '(:sync t) (chat-termini-client-pending client))
    (puthash 2 '(:sync t) (chat-termini-client-pending client))
    (chat-termini--filter
     client nil "{\"id\":2,\"result\":{\"value\":\"sec")
    (chat-termini--filter
     client nil
     "ond\"}}\n\n{\"id\":1,\"result\":{\"value\":\"first\"}}\n")
    (should (equal "second"
                   (alist-get 'value
                              (alist-get 'result
                                         (gethash 2
                                                  (chat-termini-client-responses
                                                   client))))))
    (should (equal "first"
                   (alist-get 'value
                              (alist-get 'result
                                         (gethash 1
                                                  (chat-termini-client-responses
                                                   client))))))
    (should (string-empty-p (chat-termini-client-input-buffer client)))))

(ert-deftest chat-termini-malformed-line-does-not-poison-later-records ()
  "One bad JSON line is bounded diagnostics rather than stream loss."
  (let ((client (chat-termini-test--client)))
    (puthash 1 '(:sync t) (chat-termini-client-pending client))
    (chat-termini--filter
     client nil "not-json\n{\"id\":1,\"result\":{\"ok\":true}}\n")
    (should (gethash 1 (chat-termini-client-responses client)))
    (should (eq 'protocol_error
                (alist-get 'kind (chat-termini-client-last-error client))))
    (should-not (string-match-p
                 "not-json"
                 (format "%S" (chat-termini-client-last-error client))))))

(ert-deftest chat-termini-partial-input-is-bounded-before-a-newline ()
  "A peer cannot grow the partial JSONL frame without limit."
  (let ((client (chat-termini-test--client))
        (chat-termini-max-line-bytes 8))
    (chat-termini--filter client nil "123456789")
    (should (string-empty-p (chat-termini-client-input-buffer client)))
    (should (eq 'protocol_error
                (alist-get 'kind (chat-termini-client-last-error client))))))

(ert-deftest chat-termini-stderr-retains-only-a-bounded-tail ()
  "Diagnostics cannot grow with an unbounded sidecar stderr stream."
  (let ((client (chat-termini-test--client))
        (chat-termini-max-stderr-chars 5))
    (chat-termini--stderr-filter client nil "1234")
    (chat-termini--stderr-filter client nil "5678")
    (should (equal "45678" (chat-termini-client-stderr-text client)))))

(ert-deftest chat-termini-duplicate-response-completes-callback-once ()
  "Duplicate response IDs never cross or repeat pending callbacks."
  (let* ((client (chat-termini-test--client))
         (calls 0)
         (pending (chat-termini-client-pending client)))
    (puthash 7 (list :success (lambda (_result) (setq calls (1+ calls)))
                     :error (lambda (_error) (setq calls (+ calls 100))))
             pending)
    (chat-termini--handle-message client '((id . 7) (result . ((ok . t)))))
    (chat-termini--handle-message client '((id . 7) (result . ((ok . t)))))
    (should (= 1 calls))
    (should-not (gethash 7 pending))))

(ert-deftest chat-termini-notifications-deduplicate-event-identities ()
  "A repeated event ID is delivered once per connection generation."
  (let ((client (chat-termini-test--client))
        (calls 0))
    (chat-termini-add-observer
     client (lambda (_method _params) (setq calls (1+ calls))))
    (let ((event '((method . "job/completed")
                   (params . ((eventId . "event-1") (jobId . "job-1"))))))
      (chat-termini--handle-message client event)
      (chat-termini--handle-message client event))
    (should (= 1 calls))
    (should (= 1 (length (chat-termini-client-notifications client))))))

(ert-deftest chat-termini-initialize-requires-version-and-core-methods ()
  "Negotiation fails closed before the client is marked ready."
  (let ((client (chat-termini-test--client)))
    (cl-letf (((symbol-function 'chat-termini-call)
               (lambda (_client _method _params)
                 (chat-termini-test--initialize-result nil "2099-01-01"))))
      (should-error (chat-termini-initialize client)
                    :type 'chat-termini-protocol-error))
    (cl-letf (((symbol-function 'chat-termini-call)
               (lambda (_client _method _params)
                 (chat-termini-test--initialize-result '("initialize")))))
      (should-error (chat-termini-initialize client)
                    :type 'chat-termini-capability-error))
    (should-not (eq 'ready (chat-termini-client-status client)))))

(ert-deftest chat-termini-initialize-records-advertised-capabilities ()
  "A compatible handshake makes only advertised methods available."
  (let* ((client (chat-termini-test--client))
         (methods (append chat-termini-required-methods
                          '("attachment/read"))))
    (cl-letf (((symbol-function 'chat-termini-call)
               (lambda (_client method params)
                 (should (equal "initialize" method))
                 (should (member "2026-07-08"
                                 (alist-get 'supportedProtocolVersions params)))
                 (chat-termini-test--initialize-result methods))))
      (chat-termini-initialize client))
    (should (eq 'ready (chat-termini-client-status client)))
    (should (chat-termini-capability-p client "job/list"))
    (should (chat-termini-capability-p client "attachment/read"))
    (should-not (chat-termini-capability-p client "attachment/stage"))))

(ert-deftest chat-termini-start-initializes-the-managed-execution-backend ()
  "The optional entry point can connect without loading chat.el first."
  (let ((client (chat-termini-client-create
                 :id "start" :command (list (or (executable-find "true")
                                                 "/usr/bin/true"))))
        initialized)
    (cl-letf (((symbol-function 'chat-execution-initialize)
               (lambda () (setq initialized t)))
              ((symbol-function 'chat-execution-start)
               (lambda (&rest _args) (error "stop after backend check"))))
      (should-error (chat-termini-start client)))
    (should initialized)
    (should (eq 'failed (chat-termini-client-status client)))
    (should-not (chat-termini-client-stderr-process client))))

(ert-deftest chat-termini-disconnect-fails-pending-once-and-clears-timers ()
  "Connection loss owns callback and timer cleanup without job inference."
  (let* ((client (chat-termini-test--client))
         (timer (run-at-time 60 nil #'ignore))
         (errors 0))
    (puthash 9 (list :success #'ignore
                     :error (lambda (_message) (setq errors (1+ errors)))
                     :timer timer)
             (chat-termini-client-pending client))
    (chat-termini--connection-ended client "closed")
    (chat-termini--connection-ended client "closed again")
    (should (= 1 errors))
    (should (= 0 (hash-table-count (chat-termini-client-pending client))))
    (should-not (memq timer timer-list))
    (should (eq 'disconnected (chat-termini-client-status client)))))

(ert-deftest chat-termini-command-and-cancel-preserve-caller-identities ()
  "Mutation wrappers pass one caller-generated identity unchanged."
  (let ((client (chat-termini-test--client)) calls)
    (setf (chat-termini-client-status client) 'ready
          (chat-termini-client-methods client)
          (append chat-termini-required-methods '("message/send")))
    (cl-letf (((symbol-function 'chat-termini-call)
               (lambda (_client method params)
                 (push (cons method params) calls)
                 '((accepted . t)))))
      (chat-termini-command-run client "rs-1" "/jobs" 4101)
      (chat-termini-message-send client "rs-1" "hello" "message-1")
      (chat-termini-job-cancel client "rs-1" "job-1" "cancel-1"))
    (setq calls (nreverse calls))
    (should (= 4101 (alist-get 'clientMessageId (cdr (nth 0 calls)))))
    (should (equal "message-1"
                   (alist-get 'clientMessageId (cdr (nth 1 calls)))))
    (should (equal "cancel-1"
                   (alist-get 'clientRequestId (cdr (nth 2 calls)))))))

(ert-deftest chat-termini-optional-methods-fail-before-dispatch ()
  "Capability-gated attachment calls cannot reach an older server."
  (let ((client (chat-termini-test--client)) called)
    (setf (chat-termini-client-status client) 'ready
          (chat-termini-client-methods client) chat-termini-required-methods)
    (cl-letf (((symbol-function 'chat-termini-call)
               (lambda (&rest _args) (setq called t))))
      (should-error (chat-termini-attachment-stage client "rs-1" "/tmp/a")
                    :type 'chat-termini-capability-error))
    (should-not called)))

(ert-deftest chat-termini-job-list-validates-authoritative-status ()
  "Job projections preserve the server state vocabulary and bounded fields."
  (let ((client (chat-termini-test--client)))
    (setf (chat-termini-client-status client) 'ready
          (chat-termini-client-methods client) chat-termini-required-methods)
    (cl-letf (((symbol-function 'chat-termini-call)
               (lambda (_client _method _params)
                 '((jobs . (((jobId . "job-1")
                             (runtimeSessionId . "rs-1")
                             (kind . "agent") (tool . "codex")
                             (status . "running")
                             (commandPreview . "run")
                             (acceptedAtMs . 100) (startedAtMs . 110))))))))
      (let ((job (car (chat-termini-job-list client "rs-1"))))
        (should (chat-termini-job-p job))
        (should (eq 'running (chat-termini-job-status job)))
        (should (equal "job-1" (chat-termini-job-id job)))))
    (cl-letf (((symbol-function 'chat-termini-call)
               (lambda (_client _method _params)
                 '((jobs . (((jobId . "job-2")
                             (runtimeSessionId . "rs-1")
                             (kind . "agent") (tool . "codex")
                             (status . "invented"))))))))
      (should-error (chat-termini-job-list client "rs-1")
                    :type 'chat-termini-protocol-error))))

(ert-deftest chat-termini-session-list-counts-authoritative-running-jobs ()
  "Session projections use the App Server runningJobIds field."
  (let ((client (chat-termini-test--client)))
    (setf (chat-termini-client-status client) 'ready
          (chat-termini-client-methods client) chat-termini-required-methods)
    (cl-letf (((symbol-function 'chat-termini-call)
               (lambda (_client _method _params)
                 '((sessions
                    . (((runtimeSessionId . "rs-1")
                        (displayName . "Desk")
                        (cwd . "/tmp")
                        (runningJobIds . ("job-1" "job-2")))))))))
      (let ((session (car (chat-termini-session-list client))))
        (should (= 2 (chat-termini-session-active-job-count session)))))))

(ert-deftest chat-termini-attachment-read-enforces-decoded-byte-limit ()
  "Explicit attachment reads reject oversized bytes before returning them."
  (let ((client (chat-termini-test--client))
        (chat-termini-max-attachment-bytes 4))
    (setf (chat-termini-client-status client) 'ready
          (chat-termini-client-methods client)
          (append chat-termini-required-methods '("attachment/read")))
    (cl-letf (((symbol-function 'chat-termini-call)
               (lambda (_client _method _params)
                 '((attachment . ((attachmentId . "att-1")
                                  (fileName . "a.txt")
                                  (kind . "document")
                                  (mimeType . "text/plain")
                                  (sizeBytes . 5)))
                   (encoding . "base64")
                   (data . "MTIzNDU=")
                   (truncated . :json-false)))))
      (should-error (chat-termini-attachment-read client "rs-1" "att-1")
                    :type 'chat-termini-protocol-error))))

(ert-deftest chat-termini-session-binding-is-explicit-and-persistent ()
  "Local session metadata stores only the selected RuntimeSession ID."
  (chat-test-with-temp-dir
   (let* ((chat-session-auto-save t)
          (session (chat-session-create "Bound" 'kimi)))
     (termini-bind-session "rs-remote" session)
     (should (equal "rs-remote" (termini-bound-session-id session)))
     (let ((loaded (chat-session-load (chat-session-id session))))
       (should (equal "rs-remote" (termini-bound-session-id loaded))))
     (termini-unbind-session session)
     (should-not (termini-bound-session-id session)))))

(ert-deftest chat-package-does-not-load-optional-termini-entry-point ()
  "The ordinary local runtime remains independent of the bridge package."
  (should (featurep 'chat))
  (should-not (featurep 'termini)))

(provide 'test-chat-termini-bridge)
;;; test-chat-termini-bridge.el ends here
