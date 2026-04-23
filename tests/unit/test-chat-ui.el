;;; test-chat-ui.el --- Tests for chat-ui.el -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: tests

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Unit tests for chat-ui.el UI components.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'test-helper)
(require 'chat-ui)
(require 'chat-request-diagnostics)

(ert-deftest chat-ui-setup-buffer-creates-correct-structure ()
  "Test that chat-ui-setup-buffer creates proper buffer structure."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-session-create "Test Session" 'kimi)))
     (with-temp-buffer
       (setq-local chat--current-session session)
       (chat-ui-setup-buffer session)
       (goto-char (point-min))
       (should (search-forward "Test Session" nil t))
       (goto-char (point-min))
       (should (search-forward "kimi" nil t))
       (goto-char (point-max))
       (should (search-backward ">" nil t))))))

(ert-deftest chat-ui-finalize-response-persists-tool-data ()
  "Test that finalized responses replace raw content and persist tool data."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-session-create "Test Session" 'kimi))
          (chat-ui--messages-end nil))
     (with-temp-buffer
       (setq-local chat--current-session session)
       (chat-ui-setup-buffer session)
       (goto-char chat-ui--messages-end)
       (insert "Assistant:\n")
       (set-marker chat-ui--messages-end (point))
       (let ((content-start (copy-marker (point))))
         (insert "{\"function_call\":{\"name\":\"demo\",\"arguments\":{\"input\":\"hello\"}}}")
         (set-marker chat-ui--messages-end (point))
         (chat-ui--finalize-response
          session
          "msg-1"
          (current-buffer)
          content-start
          '(:content ""
            :tool-events ((:type tool-call
                           :index 1
                           :tool "demo"
                           :arguments (("input" . "hello")))
                          (:type tool-result
                           :index 1
                           :tool "demo"
                           :result-summary "done"))
            :tool-calls ((:name "demo" :arguments (("input" . "hello"))))
            :tool-results ("done"))
          "{\"request\":true}"
          "{\"response\":true}")
         (should-not (search-backward "function_call" nil t))
         (goto-char (point-min))
         (should-not (search-forward "Steps:" nil t))
         (let ((saved (car (last (chat-session-messages session)))))
           (should (string= (chat-message-content saved) "done"))
           (should (equal (chat-message-tool-results saved) '("done")))
           (should (equal (chat-message-tool-calls saved)
                          '((:name "demo" :arguments (("input" . "hello"))))))
           (should (string= (chat-message-raw-request saved) "{\"request\":true}"))
           (should (string= (chat-message-raw-response saved) "{\"response\":true}"))))))))

(ert-deftest chat-ui-resolve-tool-loop-requests-followup-answer ()
  "Test that tool results are fed back into a follow-up model call."
  (let* ((initial-messages
          (list (make-chat-message
                 :id "user-1"
                 :role :user
                 :content "执行一个简单命令然后告诉我结果"
                 :timestamp (current-time))))
         (processed '(:content ""
                     :tool-calls ((:name "shell_execute"
                                   :arguments (("command" . "echo tool-ok"))))
                     :tool-results ("tool-ok\n")))
         captured-messages)
    (cl-letf (((symbol-function 'chat-llm-request)
               (lambda (_model messages _options)
                 (setq captured-messages messages)
                 '(:content "命令结果是 tool-ok"
                   :raw-request "{\"step\":2}"
                   :raw-response "{\"answer\":true}"))))
      (let* ((resolved (chat-ui--resolve-tool-loop
                        'kimi-code initial-messages processed "{\"step\":1}" nil))
             (final (plist-get resolved :processed))
             (followup (car (last captured-messages))))
        (should (string= (plist-get final :content) "命令结果是 tool-ok"))
        (should (equal (plist-get final :tool-results) '("tool-ok\n")))
        (should (eq (chat-message-role followup) :system))
        (should (string-match-p "Tool results from the previous step"
                                (chat-message-content followup)))
        (should (string-match-p "tool-ok"
                                (chat-message-content followup)))))))

(ert-deftest chat-ui-get-response-sync-uses-async-request-path ()
  "Test that non streaming UI requests go through the async LLM API."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-session-create "Async Session" 'kimi))
          (chat-ui--messages-end nil)
          requested)
     (chat-session-add-message
      session
      (make-chat-message
       :id "user-1"
       :role :user
       :content "Hello"
       :timestamp (current-time)))
     (with-temp-buffer
       (setq-local chat--current-session session)
       (chat-ui-setup-buffer session)
       (cl-letf (((symbol-function 'chat-llm-request-async)
                  (lambda (_model messages success _error _options)
                    (setq requested messages)
                    (funcall success
                             '(:content "Async answer"
                               :raw-request "{\"request\":true}"
                               :raw-response "{\"response\":true}"))
                    'request-handle)))
         (chat-ui--get-response-sync)
         (should requested)
         (should (equal chat-ui--active-request-handle 'request-handle))
         (let ((saved (car (last (chat-session-messages session)))))
           (should (string= (chat-message-content saved) "Async answer"))))))))

(ert-deftest chat-ui-cancel-response-cancels-non-stream-request ()
  "Test cancelling also stops an active async request handle."
  (let ((chat-ui--active-request-handle 'request-handle)
        cancelled)
    (cl-letf (((symbol-function 'chat-llm-cancel-request)
               (lambda (handle)
                 (setq cancelled handle)
                 t)))
      (chat-ui-cancel-response)
      (should (eq cancelled 'request-handle))
      (should-not chat-ui--active-request-handle))))

(ert-deftest chat-ui-send-message-blocks-while-request-is-active ()
  "Test sending a new message is blocked while another response is active."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-session-create "Busy Session" 'kimi))
          (chat-ui--active-request-handle 'request-handle)
          sent)
     (with-temp-buffer
       (setq-local chat--current-session session)
       (chat-ui-setup-buffer session)
       (goto-char (point-max))
       (insert "Hello while busy")
       (cl-letf (((symbol-function 'chat-ui--get-response)
                  (lambda ()
                    (setq sent t))))
         (chat-ui-send-message)
         (should-not sent)
         (should-not (chat-session-messages session)))))))

(ert-deftest chat-ui-resolve-tool-loop-async-requests-followup-answer ()
  "Test async tool loop requests the next model turn correctly."
  (let* ((initial-messages
          (list (make-chat-message
                 :id "user-1"
                 :role :user
                 :content "执行一个简单命令然后告诉我结果"
                 :timestamp (current-time))))
         (processed '(:content ""
                     :tool-calls ((:name "shell_execute"
                                   :arguments (("command" . "echo tool-ok"))))
                     :tool-results ("tool-ok\n")))
         captured-options
         final-result)
    (cl-letf (((symbol-function 'chat-llm-request-async)
               (lambda (_model _messages success _error options)
                 (setq captured-options options)
                 (funcall success
                          '(:content "命令结果是 tool-ok"
                            :raw-request "{\"step\":2}"
                            :raw-response "{\"answer\":true}"))
                 'request-handle))
              ((symbol-function 'chat-tool-caller-process-response-data)
               (lambda (_content &optional _session)
                 '(:content "命令结果是 tool-ok"))))
      (chat-ui--resolve-tool-loop-async
       'kimi-code
       initial-messages
       processed
       "{\"step\":1}"
       nil
       (lambda (resolved)
         (setq final-result resolved))
       (lambda (_err)
         (should nil)))
      (should (equal captured-options '(:temperature 0.7)))
      (should (equal (plist-get (plist-get final-result :processed) :tool-results)
                     '("tool-ok\n")))
      (should (string= (plist-get (plist-get final-result :processed) :content)
                       "命令结果是 tool-ok")))))

(ert-deftest chat-ui-stream-started-p-accepts-non-nil-handle ()
  "Test non-nil handles count as successful stream startup."
  (should (chat-ui--stream-started-p 'stream-handle))
  (should-not (chat-ui--stream-started-p nil)))

(ert-deftest chat-ui-format-tool-events-renders-structured-lines ()
  "Test tool events are rendered as readable step lines."
  (let ((text (chat-ui--format-tool-events
               '((:type thinking :summary "Scanning repository")
                 (:type tool-call :index 1 :tool "files_find" :arguments (("directory" . "/tmp/project")))
                 (:type approval :index 1 :tool "shell_execute" :decision allow-session)
                 (:type tool-result :index 1 :tool "files_find" :result-summary "3 matches")
                 (:type tool-error :index 2 :tool "files_find" :result-summary "Access denied")))))
    (should (string-match-p "Thinking: Scanning repository" text))
    (should (string-match-p "Tool Call 1: files_find" text))
    (should (string-match-p "Approval 1: allow-session" text))
    (should (string-match-p "Tool Result 1: 3 matches" text))
    (should (string-match-p "Tool Error 2: Access denied" text))))

(ert-deftest chat-ui-get-response-sync-attaches-request-diagnostics ()
  "Test chat UI passes a request id into the async request path."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-session-create "Diag Session" 'kimi))
          (chat-ui--messages-end nil)
          captured-options)
     (chat-session-add-message
      session
      (make-chat-message
       :id "user-1"
       :role :user
       :content "Hello"
       :timestamp (current-time)))
     (with-temp-buffer
       (setq-local chat--current-session session)
       (chat-ui-setup-buffer session)
       (cl-letf (((symbol-function 'chat-llm-request-async)
                  (lambda (_model _messages success _error options)
                    (setq captured-options options)
                    (funcall success
                             '(:content "Async answer"
                               :raw-request "{\"request\":true}"
                               :raw-response "{\"response\":true}"))
                    'request-handle)))
         (chat-ui--get-response-sync)
         (should (plist-get captured-options :request-id))
         (should-not chat-ui--current-request-id))))))

(ert-deftest chat-show-current-request-status-opens-diagnostics-buffer ()
  "Test the status command displays the current request diagnostics."
  (let ((chat-request-diagnostics--traces (make-hash-table :test 'equal))
        shown-buffer)
    (puthash "req-ui"
             (make-chat-request-trace
              :id "req-ui"
              :mode 'chat
              :provider 'kimi
              :model 'kimi
              :phase 'waiting
              :started-at (current-time)
              :updated-at (current-time))
             chat-request-diagnostics--traces)
    (with-temp-buffer
      (setq-local chat-ui--current-request-id "req-ui")
      (cl-letf (((symbol-function 'pop-to-buffer)
                 (lambda (buffer &rest _args)
                   (setq shown-buffer buffer)
                   buffer)))
        (chat-show-current-request-status)
        (should (bufferp shown-buffer))
        (with-current-buffer shown-buffer
          (should (search-forward "Request: req-ui" nil t)))))))

(ert-deftest chat-ui-toggle-request-panel-opens-panel-buffer ()
  "Test chat UI can toggle the structured request panel."
  (let ((chat-request-diagnostics--traces (make-hash-table :test 'equal))
        shown-buffer)
    (puthash "req-ui"
             (make-chat-request-trace
              :id "req-ui"
              :mode 'chat
              :provider 'kimi
              :model 'kimi
              :phase 'waiting
              :started-at (current-time)
              :updated-at (current-time))
             chat-request-diagnostics--traces)
    (with-temp-buffer
      (setq-local chat-ui--current-request-id "req-ui")
      (cl-letf (((symbol-function 'display-buffer-in-side-window)
                 (lambda (buffer _alist)
                   (setq shown-buffer buffer)
                   buffer)))
        (chat-ui-toggle-request-panel)
        (should (bufferp shown-buffer))
        (with-current-buffer shown-buffer
          (should (search-forward "Request: req-ui" nil t)))))))

(ert-deftest chat-ui-render-response-state-announces-approval-shortcuts ()
  "Test chat UI surfaces approval shortcuts in minibuffer feedback."
  (with-temp-buffer
    (let ((chat-ui--messages-end (point-max-marker)))
      (should
       (string-match-p
        "Approval pending"
        (chat-ui--maybe-announce-approval-shortcuts
         '((:type approval-pending
            :index 1
            :tool "shell_execute"
            :actions ("C-c C-a once"
                      "C-c C-s session"
                      "C-c C-t tool"
                      "C-c C-c command"
                      "C-c C-d deny"))))))
      (should-not
       (chat-ui--maybe-announce-approval-shortcuts
       '((:type approval-pending
           :index 1
           :tool "shell_execute"
           :actions ("C-c C-a once"
                     "C-c C-s session"
                     "C-c C-t tool"
                     "C-c C-c command"
                     "C-c C-d deny"))))))))

(ert-deftest chat-ui-status-line-shows-pending-approval ()
  "Test chat UI status line reflects pending approvals."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-session-create "Status Session" 'kimi)))
     (with-temp-buffer
       (setq-local chat--current-session session)
       (chat-ui-setup-buffer session)
       (setq-local chat-ui--request-tool-events
                   '((:type approval-pending
                      :index 1
                      :tool "shell_execute"
                      :actions ("C-c C-a once"
                                "C-c C-s session"
                                "C-c C-t tool"
                                "C-c C-c command"
                                "C-c C-d deny"))))
       (should (string-match-p "Approval Pending"
                               (chat-ui--status-line session)))
       (should (string-match-p "shell_execute"
                               (chat-ui--status-line session)))))))

(ert-deftest chat-ui-status-line-ignores-nonblocking-events ()
  "Test chat UI status line stays quiet for non-blocking tool events."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-session-create "Status Session" 'kimi)))
     (with-temp-buffer
       (setq-local chat--current-session session)
       (chat-ui-setup-buffer session)
       (setq-local chat-ui--request-tool-events
                   '((:type thinking :summary "Scanning")
                     (:type tool-call :index 1 :tool "files_find")))
       (should (string= (chat-ui--status-line session) "Model: kimi"))))))

(provide 'test-chat-ui)
;;; test-chat-ui.el ends here
