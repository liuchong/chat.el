;;; test-chat-code.el --- Tests for chat-code.el -*- lexical-binding: t -*-
;; Copyright (C) 2026 chat.el contributors
;; Author: chat.el contributors
;; Keywords: tests
;; This file is not part of GNU Emacs.
;;; Commentary:
;; Unit tests for chat-code.el interaction flow.
;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'test-helper)
(require 'chat-code)

(ert-deftest chat-code-setup-buffer-creates-input-markers ()
  "Test code mode buffer setup creates stable message and input markers."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-code-session-create "Code Session" temp-dir)))
     (with-temp-buffer
       (chat-code-mode)
       (setq-local chat-code--current-session session)
       (chat-code--setup-buffer session)
       (should (markerp chat-code--messages-end))
       (should (markerp chat-code--input-marker))
       (should (< (marker-position chat-code--messages-end)
                  (marker-position chat-code--input-marker)))
       (should (eq chat-code--status-state 'idle))
       (should (string= chat-code--status-detail "Ready"))
       (should header-line-format)
       (should mode-line-format)
       (goto-char (point-min))
       (should (search-forward "> " nil t))))))

(ert-deftest chat-code-send-message-persists-history-and-keeps-input-open ()
  "Test sending a code-mode message preserves history and keeps the prompt editable."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-code-session-create "Code Session" temp-dir))
          sent)
     (with-temp-buffer
       (chat-code-mode)
       (setq-local chat-code--current-session session)
       (chat-code--setup-buffer session)
       (goto-char (point-max))
       (insert "Fix this function")
       (cl-letf (((symbol-function 'chat-code--send-to-llm)
                  (lambda ()
                    (setq sent t))))
         (chat-code-send-message))
       (should sent)
       (should (= (length (chat-session-messages (chat-code-session-base-session session))) 1))
       (let ((saved (car (chat-session-messages (chat-code-session-base-session session)))))
         (should (eq (chat-message-role saved) :user))
         (should (string= (chat-message-content saved) "Fix this function")))
       (should (= (marker-position chat-code--input-marker) (point-max)))
       (goto-char (point-min))
       (should (search-forward "You:" nil t))
       (should (search-forward "Fix this function" nil t))))))

(ert-deftest chat-code-send-message-blocks-while-request-is-active ()
  "Test code mode blocks duplicate sends while another response is active."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-code-session-create "Busy Session" temp-dir))
          (chat-code--active-request-handle 'request-handle)
          sent)
     (with-temp-buffer
       (chat-code-mode)
       (setq-local chat-code--current-session session)
       (chat-code--setup-buffer session)
       (setq-local chat-code--active-request-handle 'request-handle)
       (goto-char (point-max))
       (insert "Should not send")
       (cl-letf (((symbol-function 'chat-code--send-to-llm)
                  (lambda ()
                    (setq sent t))))
         (chat-code-send-message))
       (should-not sent)
       (should-not (chat-session-messages (chat-code-session-base-session session)))))))

(ert-deftest chat-code-send-streaming-uses-current-stream-api ()
  "Test code mode streaming uses the current chat-stream API shape."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-code-session-create "Stream Session" temp-dir))
          captured-model
          captured-messages
          captured-callback
          captured-options
          sentinel-installed)
     (with-temp-buffer
       (chat-code-mode)
       (setq-local chat-code--current-session session)
       (chat-code--setup-buffer session)
       (let ((content-start (chat-code--show-assistant-indicator)))
         (cl-letf (((symbol-function 'chat-stream-request)
                    (lambda (model messages callback options)
                      (setq captured-model model)
                      (setq captured-messages messages)
                      (setq captured-callback callback)
                      (setq captured-options options)
                      'stream-handle))
                   ((symbol-function 'chat-code--set-stream-process-sentinel)
                    (lambda (_process _sentinel)
                      (setq sentinel-installed t))))
           (chat-code--send-streaming 'kimi '(message-a message-b) content-start)))
       (should (eq captured-model 'kimi))
       (should (equal captured-messages '(message-a message-b)))
       (should (functionp captured-callback))
       (should (equal captured-options
                      (list :temperature 0.7
                            :stream t
                            :max-tokens (chat-code--request-output-budget 'kimi))))
       (should (eq chat-code--active-stream-process 'stream-handle))
       (funcall captured-callback "{\"function_call\":{\"name\":\"demo\",\"arguments\":{\"input\":\"hello\"}}}")
       (goto-char (point-min))
       (should-not (search-forward "{\"function_call\"" nil t))
       (should (search-forward "Calling tools..." nil t))
       (should sentinel-installed)))))

(ert-deftest chat-code-handle-response-persists-assistant-message ()
  "Test code mode stores assistant replies and keeps the prompt ready."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-code-session-create "Reply Session" temp-dir)))
     (with-temp-buffer
       (chat-code-mode)
       (setq-local chat-code--current-session session)
       (chat-code--setup-buffer session)
       (let ((content-start (chat-code--show-assistant-indicator)))
         (setq-local chat-code--active-request-handle 'request-handle)
         (chat-code--handle-llm-response '(:content "Here is the answer.") content-start))
       (should-not chat-code--active-request-handle)
       (should (= (length (chat-session-messages (chat-code-session-base-session session))) 1))
       (let ((saved (car (chat-session-messages (chat-code-session-base-session session)))))
         (should (eq (chat-message-role saved) :assistant))
         (should (string= (chat-message-content saved) "Here is the answer.")))
       (should (eq chat-code--status-state 'success))
       (should (string= chat-code--status-detail "Completed"))
       (should (= (marker-position chat-code--input-marker) (point-max)))
       (goto-char (point-min))
       (should (search-forward "Here is the answer." nil t))))))

(ert-deftest chat-code-send-to-llm-builds-json-tool-prompt ()
  "Test code mode reuses the JSON tool-calling prompt contract."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-code-session-create "Prompt Session" temp-dir))
          captured-messages)
     (with-temp-buffer
       (chat-code-mode)
       (setq-local chat-code--current-session session)
       (chat-code--setup-buffer session)
       (let ((chat-code-use-streaming nil))
         (cl-letf (((symbol-function 'chat-context-code-build)
                    (lambda (_session)
                      (make-chat-code-context :files nil :sources nil :symbols nil :total-tokens 0)))
                   ((symbol-function 'chat-context-code-to-string)
                    (lambda (_context) "Context body"))
                   ((symbol-function 'chat-code-lsp-available-p)
                    (lambda () nil))
                   ((symbol-function 'chat-code--send-non-streaming)
                    (lambda (_model messages _content-start)
                      (setq captured-messages messages))))
           (chat-code--send-to-llm)))
       (should captured-messages)
       (let ((system-message (car captured-messages)))
         (should (eq (chat-message-role system-message) :system))
         (should (string-match-p "\"function_call\"" (chat-message-content system-message)))
         (should (string-match-p "Use this exact shape" (chat-message-content system-message)))
         (should (string-match-p "Non-negotiable rules:" (chat-message-content system-message)))
         (should (string-match-p "Obey project instruction files" (chat-message-content system-message)))
         (should (string-match-p "Programming best practices:" (chat-message-content system-message)))
         (should (string-match-p "trust the implementation" (chat-message-content system-message)))
         (should (string-match-p "Editing protocol:" (chat-message-content system-message)))
         (should (string-match-p "Prefer apply_patch for existing-file edits" (chat-message-content system-message)))
         (should (string-match-p "Operational guardrails" (chat-message-content system-message)))
         (should (string-match-p "Active project root" (chat-message-content system-message)))
         (should (string-match-p "If the user asked to create or change files" (chat-message-content system-message))))
       (should (eq chat-code--status-state 'running))
       (should (string= chat-code--status-detail "Waiting for model"))))))

(ert-deftest chat-code-send-to-llm-summarizes-older-history-before-request ()
  "Test code mode compresses older history with a summary message."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-code-session-create "History Session" temp-dir))
          (base-session (chat-code-session-base-session session))
          captured-messages)
     (chat-session-add-message
      base-session
      (make-chat-message :id "u-1" :role :user :content "first task details" :timestamp (current-time)))
     (chat-session-add-message
      base-session
      (make-chat-message :id "a-1" :role :assistant :content (make-string 240 ?a) :timestamp (current-time)))
     (chat-session-add-message
      base-session
      (make-chat-message :id "u-2" :role :user :content "latest question" :timestamp (current-time)))
     (with-temp-buffer
       (chat-code-mode)
       (setq-local chat-code--current-session session)
       (chat-code--setup-buffer session)
       (let ((chat-code-use-streaming nil)
             (chat-code-history-max-tokens 40))
         (cl-letf (((symbol-function 'chat-context-code-build)
                    (lambda (_session)
                      (make-chat-code-context :files nil :sources nil :symbols nil :total-tokens 0)))
                   ((symbol-function 'chat-context-code-to-string)
                    (lambda (_context) "Context body"))
                   ((symbol-function 'chat-code-lsp-available-p)
                    (lambda () nil))
                   ((symbol-function 'chat-code--send-non-streaming)
                    (lambda (_model messages _content-start)
                      (setq captured-messages messages))))
           (chat-code--send-to-llm)))
       (should captured-messages)
       (should (eq (chat-message-role (car captured-messages)) :system))
       (should (seq-find (lambda (msg)
                           (and (eq (chat-message-role msg) :system)
                                (string-match-p "Earlier conversation summary"
                                                (chat-message-content msg))))
                         captured-messages))
       (should (string= (chat-message-content (car (last captured-messages)))
                        "latest question"))))))

(ert-deftest chat-code-tool-followup-summarizes-structured-results ()
  "Test tool follow-up messages keep summaries instead of raw plist dumps."
  (let* ((tool-calls '((:name "files_read"
                       :arguments (("path" . "/tmp/demo.el")))))
         (tool-results '("(:path \"/tmp/demo.el\" :content \"(message \\\"hello\\\")\\n(second-line)\" :size 24)"))
         (message (chat-code--tool-followup-message tool-calls tool-results)))
    (should (string-match-p (regexp-quote "demo.el: (message") message))
    (should-not (string-match-p ":content" message))))

(ert-deftest chat-code-tool-summary-keeps-short-directory-lists-readable ()
  "Test short directory listings keep all visible file names."
  (let* ((result (mapcar (lambda (name)
                           (list :name name :path (concat "/tmp/" name) :type 'file))
                         '("a.md" "b.md" "c.md" "d.md" "e.md")))
         (summary (chat-code--tool-result-summary (format "%S" result))))
    (should (string-match-p "a.md" summary))
    (should (string-match-p "e.md" summary))))

(ert-deftest chat-code-tool-summary-shows-files-find-matches ()
  "Test files_find summaries include matched file names."
  (let* ((result '(:directory "/tmp/specs"
                  :pattern "voice|image"
                  :matches ("/tmp/specs/a.md" "/tmp/specs/b.md" "/tmp/specs/c.md")
                  :match-count 3))
         (summary (chat-code--tool-result-summary (format "%S" result))))
    (should (string-match-p "3 matches" summary))
    (should (string-match-p "a.md" summary))
    (should (string-match-p "c.md" summary))))

(ert-deftest chat-code-tool-summary-shows-read-lines-content ()
  "Test files_read_lines summaries include visible line text."
  (let* ((result '(:path "/tmp/cmd/msg.go"
                  :lines ("package cmd" "func main() {}")
                  :start 1
                  :end 2))
         (summary (chat-code--tool-result-summary (format "%S" result))))
    (should (string-match-p "msg.go" summary))
    (should (string-match-p "package cmd" summary))))

(ert-deftest chat-code-finalize-response-resolves-json-tool-call ()
  "Test code mode executes JSON tool calls and stores the follow-up answer."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-code-session-create "Tool Session" temp-dir))
          (chat-tool-forge-directory temp-dir)
          (chat-tool-forge--registry (make-hash-table :test 'eq)))
     (chat-tool-forge-register
      (make-chat-forged-tool
       :id 'demo-tool
       :name "Demo Tool"
       :description "Echo"
       :language 'elisp
       :parameters '((:name "input" :type "string" :required t))
       :compiled-function (lambda (input) (format "ran:%s" input))
       :is-active t
       :usage-count 0))
     (with-temp-buffer
       (chat-code-mode)
       (setq-local chat-code--current-session session)
       (setq-local chat-code--active-request-model 'kimi-code)
       (setq-local chat-code--active-request-messages
                   (list (make-chat-message
                          :id "user-1"
                          :role :user
                          :content "Run a tool"
                          :timestamp (current-time))))
       (chat-code--setup-buffer session)
       (let ((content-start (chat-code--show-assistant-indicator)))
         (cl-letf (((symbol-function 'chat-approval-request-tool-call)
                    (lambda (_tool _call &optional _session) t))
                   ((symbol-function 'chat-llm-request-async)
                    (lambda (_model _messages success _error _options)
                      (with-temp-buffer
                        (funcall success '(:content "Tool finished successfully."
                                           :raw-request "{\"step\":2}"
                                           :raw-response "{\"done\":true}")))
                      'followup-handle)))
           (chat-code--finalize-response
            "{\"function_call\":{\"name\":\"demo-tool\",\"arguments\":{\"input\":\"hello\"}}}"
            content-start
            "{\"step\":1}"
            "{\"tool\":true}")))
       (let ((saved (car (last (chat-session-messages (chat-code-session-base-session session))))))
         (should (string= (chat-message-content saved) "Tool finished successfully."))
         (should (equal (chat-message-tool-results saved) '("ran:hello")))
         (should (equal (plist-get (car (chat-message-tool-calls saved)) :name) "demo-tool"))
         (goto-char (point-min))
        (should (search-forward "Tool finished successfully." nil t)))))))

(ert-deftest chat-code-display-processed-response-hides-tool-json-at-loop-limit ()
  "Test code mode hides raw tool JSON when the tool loop hits its safety limit."
  (chat-test-with-temp-dir
   (let ((session (chat-code-session-create "Loop Limit" temp-dir nil)))
     (with-temp-buffer
       (setq-local chat-code--current-session session)
       (chat-code--setup-buffer session)
       (let ((content-start (chat-code--show-assistant-indicator)))
         (chat-code--display-processed-response
          '(:content "{\"function_call\":{\"name\":\"shell_execute\",\"arguments\":{\"command\":\"pwd\"}}}"
            :tool-calls ((:name "shell_execute"
                          :arguments (("command" . "pwd"))))
            :tool-results ("/tmp/project")
            :tool-loop-limit-reached t)
          content-start))
       (goto-char (point-min))
       (should-not (search-forward "{\"function_call\"" nil t))
       (should (search-forward "Tool loop stopped after reaching the safety limit." nil t))
       (should (search-forward "Tools used: shell_execute: /tmp/project" nil t))))))

(ert-deftest chat-code-handle-llm-error-updates-status ()
  "Test code mode sets failed status on request errors."
  (chat-test-with-temp-dir
   (let ((session (chat-code-session-create "Error Session" temp-dir nil)))
     (with-temp-buffer
       (chat-code-mode)
       (setq-local chat-code--current-session session)
       (chat-code--setup-buffer session)
       (chat-code--handle-llm-error "boom")
       (should (eq chat-code--status-state 'failed))
       (should (string= chat-code--status-detail "boom"))))))

(ert-deftest chat-code-cancel-updates-status ()
  "Test code mode sets cancelled status when the user stops a request."
  (chat-test-with-temp-dir
   (let ((session (chat-code-session-create "Cancel Session" temp-dir nil)))
     (with-temp-buffer
       (chat-code-mode)
       (setq-local chat-code--current-session session)
       (chat-code--setup-buffer session)
       (setq-local chat-code--active-request-handle 'request-handle)
       (cl-letf (((symbol-function 'chat-llm-cancel-request)
                  (lambda (_handle) t)))
         (chat-code-cancel))
       (should (eq chat-code--status-state 'cancelled))
       (should (string= chat-code--status-detail "Cancelled by user"))))))

(ert-deftest chat-code-tool-loop-default-is-production-sized ()
  "Test code mode tool loop default is production sized."
  (should (= chat-code-tool-loop-max-steps 100)))

(provide 'test-chat-code)
;;; test-chat-code.el ends here
