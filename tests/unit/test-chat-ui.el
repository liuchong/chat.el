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

(ert-deftest chat-set-model-retargets-and-persists-session ()
  "Test switching model updates the session, the status line and the file."
  (chat-test-with-temp-dir
   (let* ((chat-session-auto-save t)
          (session (chat-session-create "Switch Session" 'kimi)))
     (with-temp-buffer
       (setq-local chat--current-session session)
       (chat-ui-setup-buffer session)
       (chat-test-silently (chat-set-model 'kimi-code))
       (should (eq (chat-session-model-id session) 'kimi-code))
       (goto-char (point-min))
       (should (search-forward "Model: kimi-code" nil t))
       ;; Reload from disk: the switch has to survive a restart.
       (let ((reloaded (chat-session-load (chat-session-id session))))
         (should (eq (chat-session-model-id reloaded) 'kimi-code)))))))

(ert-deftest chat-set-model-slash-command-switches-without-sending ()
  "Test /model <name> in the input area switches instead of being sent.

The help text has always advertised this command."
  (chat-test-with-temp-dir
   (let* ((session (chat-session-create "Slash Session" 'kimi))
          sent)
     (with-temp-buffer
       (setq-local chat--current-session session)
       (chat-ui-setup-buffer session)
       (goto-char (point-max))
       (insert "/model kimi-code")
       (cl-letf (((symbol-function 'chat-ui--get-response)
                  (lambda () (setq sent t))))
         (chat-test-silently (chat-ui-send-message)))
       (should-not sent)
       (should-not (chat-session-messages session))
       (should (eq (chat-session-model-id session) 'kimi-code))))))

(ert-deftest chat-set-model-rejects-unknown-provider ()
  "Test switching to an unregistered provider leaves the session alone."
  (chat-test-with-temp-dir
   (let ((session (chat-session-create "Switch Session" 'kimi)))
     (with-temp-buffer
       (setq-local chat--current-session session)
       (should-error (chat-set-model 'no-such-provider) :type 'user-error)
       (should (eq (chat-session-model-id session) 'kimi))))))

(ert-deftest chat-set-model-refuses-while-response-in-flight ()
  "Test switching model is refused while a response is still arriving.

Letting it through would return the reply from a provider other than the
one that was asked."
  (chat-test-with-temp-dir
   (let ((session (chat-session-create "Switch Session" 'kimi)))
     (with-temp-buffer
       (setq-local chat--current-session session)
       (setq-local chat-ui--active-request-handle 'pending)
       (should-error (chat-set-model 'kimi-code) :type 'user-error)
       (should (eq (chat-session-model-id session) 'kimi))))))

(ert-deftest chat-set-model-offers-enabled-providers-for-completion ()
  "Test completion candidates come from the enabled provider registry."
  (let ((chat-llm-enabled-providers '(kimi kimi-code)))
    (should (equal (sort (mapcar #'symbol-name (chat-llm-enabled-providers))
                         #'string<)
                   '("kimi" "kimi-code")))))

(ert-deftest chat-ui-finalize-response-renders-without-rebundling-tools ()
  "Test finalized responses render without writing bundled tool history."
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
         (should-not (chat-session-messages session)))))))

(ert-deftest chat-ui-agent-run-persists-ordered-tool-messages ()
  "Test agent runs persist assistant and tool messages in loop order."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (chat-tool-forge--registry (make-hash-table :test 'eq))
          (session (chat-session-create "Tool Session" 'kimi))
          (session-id (chat-session-id session))
          (responses (list
                      '(:content "{\"function_call\":{\"name\":\"demo_tool\",\"arguments\":{\"input\":\"hi\"}}}"
                        :raw-request "{\"step\":1}"
                        :raw-response "{\"tool\":true}")
                      '(:content "done"
                        :raw-request "{\"step\":2}"
                        :raw-response "{\"done\":true}"))))
     (chat-tool-forge-register
      (make-chat-forged-tool
       :id 'demo_tool
       :name "Demo Tool"
       :description "Echo one argument"
       :language 'elisp
       :parameters '((:name "input" :type "string" :required t))
       :compiled-function (lambda (input) (format "echo:%s" input))
       :is-active t
       :usage-count 0))
     (chat-session-add-message
      session
      (make-chat-message
       :id "user-1"
       :role :user
       :content "Use a tool"
       :timestamp (current-time)))
     (with-temp-buffer
       (setq-local chat--current-session session)
       (chat-ui-setup-buffer session)
       (cl-letf (((symbol-function 'chat-llm-request-async)
                  (lambda (_model _messages success _error _options)
                    (funcall success (pop responses))
                    'request-handle)))
         (chat-ui--get-response-sync))
       (let ((roles (mapcar #'chat-message-role
                            (chat-session-messages session))))
         (should (equal roles '(:user :assistant :tool :assistant))))
       (let* ((messages (chat-session-messages session))
              (assistant (nth 1 messages))
              (tool (nth 2 messages)))
         (should (string= (plist-get (car (chat-message-tool-calls assistant)) :id)
                          "call-1"))
         (should (eq (chat-message-role tool) :tool))
         (should (string= (plist-get (chat-message-metadata tool) :tool-call-id)
                          "call-1"))
         (should (string-match-p "echo:hi" (chat-message-content tool))))
       (let ((loaded (chat-session-load session-id)))
         (should (equal (mapcar #'chat-message-role
                                (chat-session-messages loaded))
                        '(:user :assistant :tool :assistant))))))))

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
         (should (chat-agent-run-state-done chat-ui--active-agent-run))
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

(ert-deftest chat-ui-send-message-steers-active-agent-run ()
  "Test normal input during an agent run is queued as steering."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-session-create "Steer Session" 'kimi))
          (run (chat-agent--run-create
                :model 'kimi
                :messages nil
                :max-steps 10)))
     (with-temp-buffer
       (setq-local chat--current-session session)
       (setq-local chat-ui--active-agent-run run)
       (chat-ui-setup-buffer session)
       (goto-char (point-max))
       (insert "Add this constraint")
       (chat-ui-send-message)
       (should (= (length (chat-agent-run-state-steering-queue run)) 1))
       (should (= (length (chat-session-messages session)) 1))
       (should (string= (chat-message-content
                         (car (chat-agent-run-state-steering-queue run)))
                        "Add this constraint"))))))

(ert-deftest chat-ui-regenerate-last-response-creates-sibling-branch ()
  "Test regenerating branches without removing the original response."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-session-create "Replay Session" 'kimi))
          replayed)
     (chat-session-add-message
      session
      (make-chat-message :id "u1" :role :user :content "Question" :timestamp (current-time)))
     (chat-session-add-message
      session
      (make-chat-message :id "a1" :role :assistant :content "Old answer" :timestamp (current-time)))
     (with-temp-buffer
       (setq chat-ui--active-request-handle nil)
       (setq chat-ui--active-stream-process nil)
       (setq-local chat--current-session session)
       (chat-ui-setup-buffer session)
       (cl-letf (((symbol-function 'chat-ui--get-response)
                  (lambda ()
                    (setq replayed t))))
         (chat-ui-regenerate-last-response))
       (should replayed)
       (should (equal (mapcar #'chat-message-id (chat-session-messages session))
                      '("u1" "a1")))
       (should-not (eq chat--current-session session))
       (should (equal (mapcar #'chat-message-id
                              (chat-session-messages chat--current-session))
                      '("u1")))
       (should (equal (chat-session-parent-session-id chat--current-session)
                      (chat-session-id session)))
       (goto-char (point-min))
       (should (search-forward "Question" nil t))
       (should-not (search-forward "Old answer" nil t))))))

(ert-deftest chat-ui-edit-last-user-message-branches-and-restores-input ()
  "Test editing branches before restoring the last user message."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-session-create "Edit Session" 'kimi)))
     (chat-session-add-message
      session
      (make-chat-message :id "u1" :role :user :content "First" :timestamp (current-time)))
     (chat-session-add-message
      session
      (make-chat-message :id "a1" :role :assistant :content "Answer 1" :timestamp (current-time)))
     (chat-session-add-message
      session
      (make-chat-message :id "u2" :role :user :content "Second draft" :timestamp (current-time)))
     (chat-session-add-message
      session
      (make-chat-message :id "a2" :role :assistant :content "Answer 2" :timestamp (current-time)))
     (with-temp-buffer
       (setq-local chat--current-session session)
       (chat-ui-setup-buffer session)
       (chat-ui-edit-last-user-message)
       (should (equal (mapcar #'chat-message-id (chat-session-messages session))
                      '("u1" "a1" "u2" "a2")))
       (should (equal (mapcar #'chat-message-id
                              (chat-session-messages chat--current-session))
                      '("u1" "a1")))
       (should (string= (buffer-substring-no-properties
                         (marker-position chat-ui--input-overlay)
                         (point-max))
                        "Second draft"))
       (goto-char (point-min))
       (should (search-forward "Answer 1" nil t))
       (should-not (search-forward "Second draft\n\nAssistant" nil t))
       (should-not (search-forward "Answer 2" nil t))))))

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

(ert-deftest chat-ui-request-live-detail-reflects-stream-chunks ()
  "Test chat UI builds a useful live label from stream diagnostics."
  (let* ((now (current-time))
         (label (chat-ui--request-live-detail
                 (list :phase 'streaming
                       :stream-chunk-count 3
                       :last-chunk-at now))))
    (should (string-match-p "Receiving response (3 chunks" label))))

(ert-deftest chat-ui-handle-request-diagnostics-update-refreshes-live-transcript ()
  "Test diagnostics updates refresh the transient live narrative in transcript."
  (let ((chat-request-diagnostics--traces (make-hash-table :test 'equal)))
    (puthash "req-ui"
             (make-chat-request-trace
              :id "req-ui"
              :mode 'chat
              :provider 'kimi
              :model 'kimi
              :phase 'tool-loop
              :started-at (current-time)
              :updated-at (current-time)
              :last-event '(:type tool-loop-step :summary "Resolving tool step 1"))
             chat-request-diagnostics--traces)
    (with-temp-buffer
      (insert "Assistant:\n")
      (setq-local chat-ui--messages-end (point-max-marker))
      (let ((content-start (point-marker)))
        (setq-local chat-ui--live-start content-start)
        (setq-local chat-ui--live-response-content "")
        (setq-local chat-ui--current-request-id "req-ui")
        (chat-ui--handle-request-diagnostics-update "req-ui" nil nil)
        (goto-char content-start)
        (should (search-forward "[Live] Resolving tool step 1" nil t))))))

(ert-deftest chat-ui-track-tool-targets-promotes-single-file-followup ()
  "Test tool activity stores a single file target for later follow-up requests."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (target-file (expand-file-name "docs/spec.md" temp-dir))
          (session (chat-session-create "Track Session" 'kimi)))
     (make-directory (file-name-directory target-file) t)
     (with-temp-file target-file
       (insert "# Spec\n"))
     (with-temp-buffer
       (setq-local chat--current-session session)
       (chat-ui--track-tool-targets
        `((:type tool-call
           :tool "files_read"
           :arguments (("path" . ,target-file)))))
       (should (equal (chat-ui--session-metadata-get :chat-ui-preferred-target-path)
                      (file-truename target-file)))
       (should (member (file-truename target-file)
                       (chat-ui--session-metadata-get
                        :chat-ui-recent-target-paths)))))))

(ert-deftest chat-ui-prepare-messages-with-tools-includes-followup-target-note ()
  "Test tool prompt carries the recent file target hint for vague follow-ups."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (target-file (expand-file-name "docs/spec.md" temp-dir))
          (session (chat-session-create "Prompt Session" 'kimi))
          captured-prompt)
     (with-temp-buffer
       (setq-local chat--current-session session)
       (chat-ui--session-metadata-set :chat-ui-preferred-target-path target-file)
       (cl-letf (((symbol-function 'chat-tool-caller-build-system-prompt)
                  (lambda (prompt &optional _step-limit _session)
                    (setq captured-prompt prompt)
                    prompt)))
         (chat-ui--prepare-messages-with-tools nil))
       (should (string-match-p "Recent file target for follow-up requests" captured-prompt))
       (should (string-match-p (regexp-quote target-file) captured-prompt))))))

(ert-deftest chat-ui-send-message-persists-history-and-keeps-input-open ()
  "Sending records the message and leaves the prompt editable."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-session-create "History Session" 'kimi))
          sent)
     (with-temp-buffer
       (setq-local chat--current-session session)
       (chat-ui-setup-buffer session)
       (goto-char (point-max))
       (insert "Fix this function")
       (cl-letf (((symbol-function 'chat-ui--get-response)
                  (lambda () (setq sent t))))
         (chat-ui-send-message))
       (should sent)
       (should (= (length (chat-session-messages session)) 1))
       (let ((saved (car (chat-session-messages session))))
         (should (eq (chat-message-role saved) :user))
         (should (string= (chat-message-content saved) "Fix this function")))
       (should (= (marker-position chat-ui--input-overlay) (point-max)))
       (goto-char (point-min))
       (should (search-forward "You:" nil t))
       (should (search-forward "Fix this function" nil t))))))

(ert-deftest chat-ui-insert-newline-keeps-input-open ()
  "S-RET adds a line instead of sending."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-session-create "Newline Session" 'kimi))
          sent)
     (with-temp-buffer
       (setq-local chat--current-session session)
       (chat-ui-setup-buffer session)
       (goto-char (point-max))
       (insert "first line")
       (cl-letf (((symbol-function 'chat-ui--get-response)
                  (lambda () (setq sent t))))
         (chat-ui-insert-newline))
       (insert "second line")
       (should-not sent)
       (should (string= (buffer-substring-no-properties
                         (marker-position chat-ui--input-overlay)
                         (point-max))
                        "first line\nsecond line"))))))

(ert-deftest chat-ui-path-completion-at-point-detects-relative-path-token ()
  "Input completion offers files for a relative path fragment.

The candidates come from the project the session was pointed at, not
from wherever the buffer happens to sit."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (doc-dir (expand-file-name "docs" temp-dir))
          (session (chat-session-create "Path Session" 'kimi)))
     (make-directory doc-dir t)
     (with-temp-file (expand-file-name "guide.md" doc-dir) (insert "hello"))
     (chat-session-metadata-set session 'code-enabled t)
     (chat-session-metadata-set session 'project-root temp-dir)
     (with-temp-buffer
       (setq-local chat--current-session session)
       (setq-local default-directory "/")
       (chat-ui-setup-buffer session)
       (goto-char (point-max))
       (insert "See docs/gu")
       (let* ((capf (chat-ui--path-completion-at-point))
              (start (nth 0 capf))
              (end (nth 1 capf))
              (table (nth 2 capf))
              (candidates (all-completions "docs/gu" table)))
         (should capf)
         (should (string= (buffer-substring-no-properties start end) "docs/gu"))
         (should (member "docs/guide.md" candidates)))))))

(ert-deftest chat-ui-auto-path-completion-only-triggers-for-path-like-input ()
  "Typing an ordinary word does not open a file completion popup."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-session-create "Auto Path Session" 'kimi))
          path-triggered
          plain-triggered)
     (with-temp-buffer
       (setq-local chat--current-session session)
       (chat-ui-setup-buffer session)
       (goto-char (point-max))
       (insert "docs/gu")
       (let ((last-command-event ?u))
         (cl-letf (((symbol-function 'completion-at-point)
                    (lambda () (setq path-triggered t))))
           (chat-ui--maybe-complete-path-after-insert)))
       (delete-region (marker-position chat-ui--input-overlay) (point-max))
       (goto-char (point-max))
       (insert "plainword")
       (let ((last-command-event ?d))
         (cl-letf (((symbol-function 'completion-at-point)
                    (lambda () (setq plain-triggered t))))
           (chat-ui--maybe-complete-path-after-insert))))
     (should path-triggered)
     (should-not plain-triggered))))

(ert-deftest chat-ui-fence-safe-prefix-length-tracks-open-fences ()
  "A streaming cut never lands inside an unfinished code block."
  ;; Nothing fenced, and nothing fenced left open: all of it can be kept.
  (should (= (chat-ui--fence-safe-prefix-length "no fences here")
             (length "no fences here")))
  (let ((closed "text ```el\n(one)\n```\ntail"))
    (should (= (chat-ui--fence-safe-prefix-length closed) (length closed))))
  ;; An open fence means everything from it onward may still be
  ;; reformatted, so the safe prefix stops before it.
  (should (= (chat-ui--fence-safe-prefix-length "intro ```el\n(part") 0))
  (should (= (chat-ui--fence-safe-prefix-length "a ```x\n1\n``` b ```y\n2")
             (length "a ```x\n1\n```"))))

(ert-deftest chat-ui-finalize-hides-tool-json-at-loop-limit ()
  "A stalled tool loop shows why it stopped, not the raw call JSON."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-session-create "Loop Limit" 'kimi)))
     (with-temp-buffer
       (setq-local chat--current-session session)
       (chat-ui-setup-buffer session)
       (let ((content-start (copy-marker chat-ui--messages-end)))
         (chat-ui--finalize-response
          session "msg-1" (current-buffer) content-start
          '(:content "{\"function_call\":{\"name\":\"shell_execute\",\"arguments\":{\"command\":\"pwd\"}}}"
            :tool-calls ((:name "shell_execute"
                          :arguments (("command" . "pwd"))))
            :tool-results ("/tmp/project")
            :tool-loop-limit-reached t)))
       (goto-char (point-min))
       (should-not (search-forward "{\"function_call\"" nil t))
       (goto-char (point-min))
       (should (search-forward "Tool loop stopped after reaching the safety limit."
                               nil t))))))

(ert-deftest chat-ui-tool-summary-keeps-short-directory-lists-readable ()
  "A short directory listing keeps every file name visible."
  (let* ((result (mapcar (lambda (name)
                           (list :name name :path (concat "/tmp/" name)
                                 :type 'file))
                         '("a.md" "b.md" "c.md" "d.md" "e.md")))
         (summary (chat-ui--tool-result-summary (format "%S" result))))
    (should (string-match-p "a.md" summary))
    (should (string-match-p "e.md" summary))))

(ert-deftest chat-ui-tool-summary-shows-files-find-matches ()
  "A search summary names what it matched."
  (let* ((result '(:directory "/tmp/specs"
                   :pattern "voice|image"
                   :matches ("/tmp/specs/a.md" "/tmp/specs/b.md" "/tmp/specs/c.md")
                   :match-count 3))
         (summary (chat-ui--tool-result-summary (format "%S" result))))
    (should (string-match-p "3 matches" summary))
    (should (string-match-p "a.md" summary))
    (should (string-match-p "c.md" summary))))

(ert-deftest chat-ui-tool-summary-shows-read-lines-content ()
  "A line-range read summary shows the lines, not just the path."
  (let* ((result '(:path "/tmp/cmd/msg.go"
                   :lines ("package cmd" "func main() {}")
                   :start 1
                   :end 2))
         (summary (chat-ui--tool-result-summary (format "%S" result))))
    (should (string-match-p "msg.go" summary))
    (should (string-match-p "package cmd" summary))))

(ert-deftest chat-ui-tool-followup-summarizes-structured-results ()
  "Tool follow-up messages carry the real result content.

Structured results go back to the model up to
`chat-tool-caller-result-max-chars', so it sees file contents rather
than a one-line description of them."
  (let* ((tool-calls '((:name "files_read"
                        :arguments (("path" . "/tmp/demo.el")))))
         (tool-results
          '("(:path \"/tmp/demo.el\" :content \"(message \\\"hello\\\")\\n(second-line)\" :size 24)"))
         (message (chat-ui--tool-followup-message tool-calls tool-results)))
    (should (string-match-p (regexp-quote "(message \\\"hello\\\")") message))
    (should (string-match-p (regexp-quote "(second-line)") message))))

(ert-deftest chat-ui-prepare-messages-carries-the-coding-prompt-for-a-code-session ()
  "A code-capable session gets its coding rules from the single pipeline.

Code capability used to imply a second request path, which is how code
sessions ended up never reading the project's own instructions.  Here
both arrive from the same place."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (chat-project-instructions-max-chars 4000)
          (session (chat-session-create "Code Session" 'kimi))
          captured-prompt)
     (write-region "Always run the linter.\n" nil
                   (expand-file-name "AGENTS.md" temp-dir))
     (chat-session-metadata-set session 'code-enabled t)
     (with-temp-buffer
       (setq-local default-directory temp-dir)
       (setq-local chat--current-session session)
       (cl-letf (((symbol-function 'chat-tool-caller-build-system-prompt)
                  (lambda (prompt &optional _step-limit _session)
                    (setq captured-prompt prompt)
                    prompt))
                 ((symbol-function 'chat-context-code-build)
                  (lambda (_session) 'context))
                 ((symbol-function 'chat-context-code-to-string)
                  (lambda (_context) "Project files: main.el"))
                 ((symbol-function 'chat-code-lsp-available-p) #'ignore))
         (chat-ui--prepare-messages-with-tools nil))
       ;; The coding rules replace the generic assistant preamble.
       (should (string-match-p "Editing protocol" captured-prompt))
       (should-not (string-match-p "You are a helpful AI assistant"
                                   captured-prompt))
       ;; The project context the session was pointed at.
       (should (string-match-p "Project files: main.el" captured-prompt))
       ;; And the project's own instructions, which the separate code
       ;; path never read.
       (should (string-match-p "Always run the linter" captured-prompt))))))

(ert-deftest chat-ui-prepare-messages-leaves-a-plain-session-alone ()
  "A session without code capability keeps the generic preamble."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-session-create "Plain Session" 'kimi))
          captured-prompt)
     (with-temp-buffer
       (setq-local default-directory temp-dir)
       (setq-local chat--current-session session)
       (cl-letf (((symbol-function 'chat-tool-caller-build-system-prompt)
                  (lambda (prompt &optional _step-limit _session)
                    (setq captured-prompt prompt)
                    prompt)))
         (chat-ui--prepare-messages-with-tools nil))
       (should (string-match-p "You are a helpful AI assistant" captured-prompt))
       (should-not (string-match-p "Editing protocol" captured-prompt))))))

(ert-deftest chat-ui-handle-shell-command-cd-special-case ()
  "Test that a plain cd takes the directory-change path, not the shell."
  (chat-test-with-temp-dir
   (let (shell-ran)
     (with-temp-buffer
       (cl-letf (((symbol-function 'chat-ui--insert-system-message) #'ignore)
                 ((symbol-function 'chat-ui--execute-shell-safe)
                  (lambda (_cmd) (setq shell-ran t) "out")))
         (chat-ui--handle-shell-command (concat "cd " temp-dir))
         (should-not shell-ran)
         (should (string= default-directory
                          (file-name-as-directory (expand-file-name temp-dir))))
         (chat-ui--handle-shell-command (concat "cd " temp-dir " && ls"))
         (should shell-ran))))))

(ert-deftest chat-ui-change-directory-persists-onto-the-session ()
  "A directory change records itself so a reopened session keeps it."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (chat-session-auto-save t)
          (target (expand-file-name "target" temp-dir))
          (session (chat-session-create "Cd Session" 'kimi)))
     (make-directory target t)
     (with-temp-buffer
       (setq-local chat--current-session session)
       (cl-letf (((symbol-function 'chat-ui--insert-system-message) #'ignore))
         (chat-ui--change-directory target)
         (should (string= default-directory (file-name-as-directory target)))))
     (let ((loaded (chat-session-load (chat-session-id session))))
       (should (string= (file-name-as-directory target)
                        (chat-session-working-directory loaded)))))))

(ert-deftest chat-ui-change-directory-reports-a-missing-directory ()
  "A directory that does not exist is reported and changes nothing."
  (chat-test-with-temp-dir
   (let ((messages nil))
     (with-temp-buffer
       (let ((original default-directory))
         (cl-letf (((symbol-function 'chat-ui--insert-system-message)
                    (lambda (text) (push text messages))))
           (chat-ui--change-directory "/nonexistent-chat-el-target/")
           (should (string= default-directory original))
           (should (string-match-p "not found" (car messages)))))))))

(ert-deftest chat-ui-change-directory-accepts-fullwidth-path-punctuation ()
  "A path typed with fullwidth slash and tilde still resolves."
  (chat-test-with-temp-dir
   (with-temp-buffer
     (cl-letf (((symbol-function 'chat-ui--insert-system-message) #'ignore))
       (let* ((home (expand-file-name "home" temp-dir))
              (nested (expand-file-name "nested" home)))
         (make-directory nested t)
         (let ((process-environment (cons (concat "HOME=" home)
                                          process-environment)))
           (chat-ui--change-directory "～／nested")
           (should (string= default-directory
                            (file-name-as-directory nested)))))))))

(ert-deftest chat-ui-directory-command-target-reads-a-lone-cd ()
  "Only a lone cd is intercepted; a compound command reaches the shell."
  (should (equal "/tmp" (chat-ui--directory-command-target "cd /tmp")))
  (should (equal "~" (chat-ui--directory-command-target "cd")))
  (should-not (chat-ui--directory-command-target "cd /tmp && ls"))
  (should-not (chat-ui--directory-command-target "cd /tmp; ls"))
  (should-not (chat-ui--directory-command-target "cdate")))

(ert-deftest chat-ui-repeat-shell-command-reruns-the-last-one ()
  "A doubled bang reruns the previous command and reports when there is none."
  (chat-test-with-temp-dir
   (let ((ran nil)
         (messages nil))
     (with-temp-buffer
       (cl-letf (((symbol-function 'chat-ui--insert-system-message)
                  (lambda (text) (push text messages)))
                 ((symbol-function 'chat-ui--execute-shell-safe)
                  (lambda (cmd) (push cmd ran) "out")))
         (chat-ui--repeat-shell-command)
         (should-not ran)
         (should (string-match-p "repeat" (car messages)))
         (chat-ui--handle-shell-command "echo one")
         (chat-ui--repeat-shell-command)
         (should (equal '("echo one" "echo one") ran)))))))

(ert-deftest chat-ui-shell-command-does-not-record-a-directory-change ()
  "A cd is not remembered as the command to repeat."
  (chat-test-with-temp-dir
   (let ((ran nil))
     (with-temp-buffer
       (cl-letf (((symbol-function 'chat-ui--insert-system-message) #'ignore)
                 ((symbol-function 'chat-ui--execute-shell-safe)
                  (lambda (cmd) (push cmd ran) "out")))
         (chat-ui--handle-shell-command "echo one")
         (chat-ui--handle-shell-command (concat "cd " temp-dir))
         (chat-ui--repeat-shell-command)
         (should (equal '("echo one" "echo one") ran)))))))

(ert-deftest chat-ui-execute-shell-safe-uses-a-real-shell-when-unrestricted ()
  "A typed command reaches the system shell, so a pipe works."
  (let ((chat-ui-shell-unrestricted t))
    (should (string-match-p
             "\\`2"
             (string-trim (chat-ui--execute-shell-safe "printf 'a\\nb\\n' | wc -l")))))
  ;; Held to the tool restrictions, the same command is refused.
  (let ((chat-ui-shell-unrestricted nil)
        (chat-tool-shell-enabled t))
    (should (string-match-p "not allowed"
                            (chat-ui--execute-shell-safe "printf x | wc -l")))))

(ert-deftest chat-ui-slash-commands-cover-the-documented-names ()
  "Every command named in the help text has a handler."
  (dolist (name '("cancel" "help" "model" "send" "quick" "?" "cmd" "!"
                  "queue" "flush" "drop" "cd" "pwd" "new" "list" "save"
                  "clear" "auto"))
    (let ((handler (chat-ui--command-handler name)))
      (should handler)
      (should (fboundp handler)))))

(ert-deftest chat-ui-every-command-entry-is-complete ()
  "A table entry without a name or a callable handler is unreachable."
  (should chat-ui--command-table)
  (dolist (entry chat-ui--command-table)
    (let ((name (plist-get entry :name))
          (handler (plist-get entry :handler)))
      (should (stringp name))
      (should (not (string-empty-p name)))
      (should (fboundp handler)))))

(ert-deftest chat-ui-control-command-limits-what-runs-during-a-response ()
  "Only cancel and model are reachable while a response is in flight."
  (should (chat-ui--control-command (chat-command-parse "/cancel")))
  (should (chat-ui--control-command (chat-command-parse "／model kimi")))
  (should-not (chat-ui--control-command (chat-command-parse "/cd /tmp")))
  (should-not (chat-ui--control-command (chat-command-parse "!ls")))
  (should-not (chat-ui--control-command (chat-command-parse "hello"))))

(ert-deftest chat-ui-dispatch-routes-parsed-commands ()
  "Each command kind reaches its handler, and an unknown name is text."
  (let ((calls nil))
    (cl-letf (((symbol-function 'chat-ui--command-shell)
               (lambda (arg) (push (cons 'shell arg) calls)))
              ((symbol-function 'chat-ui--repeat-shell-command)
               (lambda () (push '(repeat) calls)))
              ((symbol-function 'chat-ui--command-quick)
               (lambda (arg) (push (cons 'quick arg) calls)))
              ((symbol-function 'chat-ui--command-cd)
               (lambda (arg) (push (cons 'cd arg) calls)))
              ((symbol-function 'chat-ui--send-user-message)
               (lambda (arg) (push (cons 'message arg) calls))))
      (chat-ui--dispatch-command (chat-command-parse "！ls -l"))
      (chat-ui--dispatch-command (chat-command-parse "！！"))
      (chat-ui--dispatch-command (chat-command-parse "？why"))
      (chat-ui--dispatch-command (chat-command-parse "／cd /tmp"))
      (chat-ui--dispatch-command (chat-command-parse "/wiki-lint now"))
      (chat-ui--dispatch-command (chat-command-parse "\\!literal"))
      (chat-ui--dispatch-command (chat-command-parse "plain text"))
      (should (equal '((shell . "ls -l")
                       (repeat)
                       (quick . "why")
                       (cd . "/tmp")
                       (message . "/wiki-lint now")
                       (message . "!literal")
                       (message . "plain text"))
                     (nreverse calls))))))

;; ------------------------------------------------------------------
;; Getting around the input area
;; ------------------------------------------------------------------

(ert-deftest chat-ui-beginning-of-input-stops-after-the-prompt ()
  "The prompt is buffer text, so the line begins before it.

Landing there is not harmless: typing inserts outside the input area and
`C-k' takes the prompt with it."
  (with-temp-buffer
    (chat-ui--setup-input-area)
    (insert "some text")
    (chat-ui-beginning-of-input)
    (should (= (point) (marker-position chat-ui--input-overlay)))
    (should-not (= (point) (line-beginning-position)))))

(ert-deftest chat-ui-beginning-of-input-still-works-on-a-second-line ()
  "Inside a multi-line message the line start is what is wanted."
  (with-temp-buffer
    (chat-ui--setup-input-area)
    (insert "first line\nsecond line")
    (chat-ui-beginning-of-input)
    (should (= (point) (line-beginning-position)))
    (should (looking-at "second line"))))

(ert-deftest chat-ui-beginning-of-input-outside-the-input-area ()
  "Above the prompt it is an ordinary movement command."
  (with-temp-buffer
    (insert "transcript line\n")
    (chat-ui--setup-input-area)
    (goto-char (point-min))
    (end-of-line)
    (chat-ui-beginning-of-input)
    (should (= (point) (point-min)))))

;; ------------------------------------------------------------------
;; Completing what you are typing
;; ------------------------------------------------------------------

(ert-deftest chat-ui-a-leading-slash-offers-commands-not-directories ()
  "`/' at the prompt is a command, and answering with the root directory
is answering a different question."
  (with-temp-buffer
    (chat-ui--setup-input-area)
    (insert "/")
    (let ((completion (chat-ui--command-completion-at-point)))
      (should completion)
      (should (member "help" (nth 2 completion)))
      (should (member "cmd" (nth 2 completion))))
    ;; And the path completion declines it, so the two cannot both fire.
    (should-not (chat-ui--path-completion-at-point))))

(ert-deftest chat-ui-a-partial-command-narrows-to-it ()
  "Completion starts after the slash, so the names match directly."
  (with-temp-buffer
    (chat-ui--setup-input-area)
    (insert "/he")
    (let ((completion (chat-ui--command-completion-at-point)))
      (should completion)
      (should (equal (buffer-substring-no-properties (nth 0 completion)
                                                     (nth 1 completion))
                     "he")))))

(ert-deftest chat-ui-a-second-slash-makes-it-a-path-again ()
  "`/Users/liu' is a path.  The ambiguity resolves as soon as it can."
  (with-temp-buffer
    (chat-ui--setup-input-area)
    (insert "/tmp/")
    (should-not (chat-ui--command-completion-at-point))
    (should (chat-ui--path-completion-at-point))))

(ert-deftest chat-ui-a-slash-mid-message-is-a-path ()
  "Only the slash that opens the input is a command."
  (with-temp-buffer
    (chat-ui--setup-input-area)
    (insert "look at /")
    (should-not (chat-ui--command-completion-at-point))
    (should (chat-ui--path-completion-at-point))))

;; ------------------------------------------------------------------
;; Shell output
;; ------------------------------------------------------------------

(ert-deftest chat-ui-expands-tabs-against-shell-tab-stops ()
  "`ls -C' pads columns with tabs and counts on stops every eight.

A buffer set to any other `tab-width' -- four is a common default --
renders that output ragged, so the tabs are expanded here instead."
  (should (equal (chat-ui--expand-tabs "ab\tc") "ab      c"))
  (should (equal (chat-ui--expand-tabs "abcdefgh\tc")
                 (concat "abcdefgh" (make-string 8 ?\s) "c")))
  ;; Two columns that started aligned stay aligned.
  (let* ((expanded (chat-ui--expand-tabs "a\t\tx\nlonger-name\tx"))
         (lines (split-string expanded "\n")))
    (should (= (string-match "x" (nth 0 lines))
               (string-match "x" (nth 1 lines))))))

(ert-deftest chat-ui-expands-tabs-by-display-width ()
  "A line of CJK output lands where the shell meant it to."
  (let* ((expanded (chat-ui--expand-tabs "中文\tx"))
         (column (string-width (substring expanded
                                          0 (string-match "x" expanded)))))
    (should (= column 8))))

(ert-deftest chat-ui-leaves-text-without-tabs-alone ()
  "The common case pays nothing."
  (should (equal (chat-ui--expand-tabs "plain output\n") "plain output\n")))

(ert-deftest chat-ui-shell-colour-becomes-a-face-not-noise ()
  "Tools emit SGR escapes when they think they have a terminal."
  (let ((decorated (chat-ui--decorate-shell-text "\e[31mred\e[0m tail")))
    (should-not (string-match-p "\e\\[" decorated))
    (should (string-match-p "red" decorated))
    (should (string-match-p "tail" decorated))))

(ert-deftest chat-ui-a-shell-line-is-marked-as-one ()
  "The command is what you search a transcript for, so it stands out."
  (with-temp-buffer
    (setq-local chat-ui--messages-end (point-max-marker))
    (chat-ui--insert-shell-echo "ls -l")
    (goto-char (point-min))
    (should (search-forward "ls -l" nil t))
    (let ((face (get-text-property (- (point) 1) 'face)))
      (should (eq face 'chat-ui-shell-command-face)))))

(ert-deftest chat-ui-shell-output-keeps-the-colour-it-asked-for ()
  "The base face is appended, so it sits under the output's own colour."
  (with-temp-buffer
    (setq-local chat-ui--messages-end (point-max-marker))
    (chat-ui--insert-shell-output "\e[31mred\e[0m plain")
    (goto-char (point-min))
    (should (search-forward "red" nil t))
    (let ((faces (get-text-property (- (point) 1) 'face)))
      ;; The output's colour is still there, with the base face behind it.
      (should (memq 'chat-ui-shell-output-face (ensure-list faces)))
      (should (> (length (ensure-list faces)) 1)))
    (should (search-forward "plain" nil t))
    (should (memq 'chat-ui-shell-output-face
                  (ensure-list (get-text-property (- (point) 1) 'face))))))

;; ------------------------------------------------------------------
;; Help
;; ------------------------------------------------------------------

(ert-deftest chat-ui-help-is-a-command-you-can-type ()
  "`/help' is the first thing someone types when they are stuck.

It used to fall through to the model as ordinary text, which answered a
request for the command list with a tool error."
  (should (chat-ui--command-handler "help"))
  (should (eq (chat-ui--command-handler "help") 'chat-ui--command-help)))

(ert-deftest chat-ui-help-works-while-a-response-is-running ()
  "Being stuck is not less true while the model is talking."
  (should (chat-ui--control-command (chat-command-parse "/help"))))

(ert-deftest chat-ui-help-on-a-topic-shows-the-lines-that-mention-it ()
  "The whole help is long; a topic is the way in."
  (with-temp-buffer
    (setq-local chat-ui--messages-end (point-max-marker))
    (chat-ui--command-help "auto")
    (let ((shown (buffer-substring-no-properties (point-min) (point-max))))
      (should (string-match-p "auto" shown))
      (should-not (string-match-p "Quote active region" shown)))))

(ert-deftest chat-ui-help-on-an-unknown-topic-says-so ()
  "Silence would read as a broken command."
  (with-temp-buffer
    (setq-local chat-ui--messages-end (point-max-marker))
    (chat-ui--command-help "nonsense-topic")
    (should (string-match-p
             "Nothing in the help"
             (buffer-substring-no-properties (point-min) (point-max))))))

;; ------------------------------------------------------------------
;; The default command
;; ------------------------------------------------------------------

(defmacro chat-ui-auto-test--with-session (&rest body)
  "Evaluate BODY in a buffer holding a saved session and a stubbed shell."
  (declare (indent 0))
  `(chat-test-with-temp-dir
    (let* ((chat-session-directory temp-dir)
           (session (chat-session-create "Auto" 'kimi))
           (shell-calls nil)
           (sent nil))
      (with-temp-buffer
        (setq-local chat--current-session session)
        (chat-ui-setup-buffer session)
        (cl-letf (((symbol-function 'chat-ui--handle-shell-command)
                   (lambda (command) (push command shell-calls)))
                  ((symbol-function 'chat-ui--send-user-message)
                   (lambda (content) (push content sent))))
          ,@body)))))

(ert-deftest chat-ui-auto-is-off-until-a-repeatable-command-runs ()
  "Plain input goes to the model until something claims it."
  (chat-ui-auto-test--with-session
    (should (equal (chat-ui-default-command) chat-ui-baseline-command))
    (should-not (chat-ui-default-command-claimed-p))
    (chat-ui--dispatch-command (chat-command-parse "hello there"))
    (should (equal sent '("hello there")))
    (should-not shell-calls)))

(ert-deftest chat-ui-a-shell-command-claims-plain-input ()
  "Shell work comes in runs, so the prefix is needed once."
  (chat-ui-auto-test--with-session
    (chat-ui--dispatch-command (chat-command-parse "!ls"))
    (should (equal (chat-ui-default-command) "cmd"))
    (chat-ui--dispatch-command (chat-command-parse "pwd"))
    (should (equal shell-calls '("pwd" "ls")))
    ;; The model was never asked, which is the whole point and also the
    ;; risk: it has to be visible.
    (should-not sent)))

(ert-deftest chat-ui-auto-says-so-in-the-status-line ()
  "A mode nobody can see is a mode that eats prose."
  (chat-ui-auto-test--with-session
    (chat-ui--dispatch-command (chat-command-parse "!ls"))
    (should (string-match-p "auto: /cmd" (chat-ui--status-line session)))
    (should (string-match-p
             "auto: /cmd"
             (buffer-substring-no-properties (point-min) (point-max))))))

(ert-deftest chat-ui-auto-off-returns-plain-input-to-the-model ()
  "There is a way back, and it is one command."
  (chat-ui-auto-test--with-session
    (chat-ui--dispatch-command (chat-command-parse "!ls"))
    (chat-ui--dispatch-command (chat-command-parse "/auto off"))
    (should-not (chat-ui-default-command-claimed-p))
    (chat-ui--dispatch-command (chat-command-parse "hello"))
    (should (equal sent '("hello")))
    (should (equal shell-calls '("ls")))
    (should-not (string-match-p "auto:" (chat-ui--status-line session)))))

(ert-deftest chat-ui-asking-the-model-gets-you-out-of-shell-mode ()
  "A question hands plain input back, whichever way it is asked.

This is the bug this design replaced.  With only `/cmd' able to hold
plain input, a session that had run one shell command stayed a shell: an
explicit question worked, and then the next line went to the shell again.
Every way of reaching the model now releases the claim."
  (chat-ui-auto-test--with-session
    (cl-letf (((symbol-function 'chat-ui--handle-direct-query) #'ignore))
      (chat-ui--dispatch-command (chat-command-parse "!ls"))
      (should (equal (chat-ui-default-command) "cmd"))
      ;; The `?' shorthand, which is what a reader reaches for first.
      (chat-ui--dispatch-command (chat-command-parse "?what does ls do"))
      (should-not (chat-ui-default-command-claimed-p))
      (chat-ui--dispatch-command (chat-command-parse "and what about du"))
      (should (equal sent '("and what about du")))
      (should (equal shell-calls '("ls")))
      ;; And again by name, to be sure the release is on the command
      ;; rather than on the prefix that reached it.
      (chat-ui--dispatch-command (chat-command-parse "!du"))
      (should (equal (chat-ui-default-command) "cmd"))
      (chat-ui--dispatch-command (chat-command-parse "/quick why"))
      (should-not (chat-ui-default-command-claimed-p)))))

(ert-deftest chat-ui-sending-is-a-command-with-a-name ()
  "The main path is nameable, which is what auto returns to."
  (chat-ui-auto-test--with-session
    (chat-ui--dispatch-command (chat-command-parse "!ls"))
    (chat-ui--dispatch-command (chat-command-parse "/send back to talking"))
    (should (equal sent '("back to talking")))
    (should-not (chat-ui-default-command-claimed-p))))

(ert-deftest chat-ui-there-is-one-name-for-each-way-of-asking ()
  "`/ask' and `/question' are gone, not reassigned.

Four names once reached the ephemeral aside and none reached the recorded
conversation.  Naming the conversation `/send' fixed the gap; deleting
these two fixed the ambiguity, which reassigning them would not have.
Both read equally well as either command, so whichever one they pointed
at, a reader would have had to remember which."
  (should (chat-ui--command-handler "send"))
  (should (chat-ui--command-handler "quick"))
  (should-not (eq (chat-ui--command-handler "send")
                  (chat-ui--command-handler "quick")))
  (should-not (chat-ui--command-handler "ask"))
  (should-not (chat-ui--command-handler "question"))
  ;; Only punctuation is a second spelling, because punctuation cannot be
  ;; mistaken for a word that means something slightly different.
  (should (eq (chat-ui--command-handler "?")
              (chat-ui--command-handler "quick")))
  (should (eq (chat-ui--command-handler "!")
              (chat-ui--command-handler "cmd"))))

(ert-deftest chat-ui-a-deleted-command-name-is-ordinary-text ()
  "Removing a name must not turn it into an error.

`/ask look at this' now reaches the model as what it says, which is the
same thing any unrecognized slash does."
  (chat-ui-auto-test--with-session
    (chat-ui--dispatch-command (chat-command-parse "/ask look at this"))
    (should (equal sent '("/ask look at this")))))

(ert-deftest chat-ui-the-prompt-says-which-command-holds-the-line ()
  "The status line is at the top; the cursor is at the bottom."
  (chat-ui-auto-test--with-session
    (should (equal (chat-ui--input-prompt) "> "))
    (chat-ui--dispatch-command (chat-command-parse "!ls"))
    (should (string-prefix-p "cmd> " (chat-ui--input-prompt)))
    (should (string-match-p
             "cmd> "
             (buffer-substring-no-properties (point-min) (point-max))))
    ;; And the marker still points just past it, or C-a and sending would
    ;; both be off by the width of the word.
    (should (equal "cmd> "
                   (buffer-substring-no-properties
                    (line-beginning-position)
                    (marker-position chat-ui--input-overlay))))
    (chat-ui--dispatch-command (chat-command-parse "/auto off"))
    (should (equal (chat-ui--input-prompt) "> "))
    (should-not (string-match-p
                 "cmd> "
                 (buffer-substring-no-properties (point-min) (point-max))))))

(ert-deftest chat-ui-typing-survives-the-prompt-being-rewritten ()
  "The prompt is redrawn in a live input area, which may not be empty."
  (chat-ui-auto-test--with-session
    (goto-char (point-max))
    (insert "half a thought")
    (chat-ui--set-default-command "cmd")
    (chat-ui--render-input-prompt)
    (should (equal "half a thought"
                   (buffer-substring-no-properties
                    (marker-position chat-ui--input-overlay)
                    (point-max))))))

(ert-deftest chat-ui-a-slash-command-still-runs-while-auto-is-on ()
  "Auto claims plain input only.  An explicit command still means itself."
  (chat-ui-auto-test--with-session
    (chat-ui--dispatch-command (chat-command-parse "!ls"))
    (cl-letf (((symbol-function 'chat-ui--command-pwd)
               (lambda (_arg) (push "pwd-command" sent))))
      (chat-ui--dispatch-command (chat-command-parse "/pwd")))
    (should (equal sent '("pwd-command")))
    (should (equal shell-calls '("ls")))))

(ert-deftest chat-ui-the-literal-escape-outruns-auto ()
  "One line must always be able to reach the model unread."
  (chat-ui-auto-test--with-session
    (chat-ui--dispatch-command (chat-command-parse "!ls"))
    (chat-ui--dispatch-command (chat-command-parse "\\what does ls do?"))
    (should (equal sent '("what does ls do?")))
    (should (equal shell-calls '("ls")))))

(ert-deftest chat-ui-auto-survives-a-reopen ()
  "The default is on the session, so reopening does not silently drop it."
  (chat-ui-auto-test--with-session
    (chat-ui--dispatch-command (chat-command-parse "!ls"))
    (chat-session-save session)
    (let ((reloaded (chat-session-load (chat-session-id session))))
      (with-temp-buffer
        (setq-local chat--current-session reloaded)
        (chat-ui-setup-buffer reloaded)
        (should (equal (chat-ui-default-command) "cmd"))
        ;; And the reopened buffer says so, rather than leaving auto on
        ;; with nothing on screen to explain it.
        (should (string-match-p
                 "auto: /cmd"
                 (buffer-substring-no-properties (point-min) (point-max))))))))

(ert-deftest chat-ui-steering-a-live-run-outranks-auto ()
  "While a run is going, plain input is talking to it.

Auto claims plain input when nothing else has a claim on it.  A live
agent does: sending its input to a shell instead would race the run and
lose what you meant to tell it."
  (chat-ui-auto-test--with-session
    (chat-ui--dispatch-command (chat-command-parse "!ls"))
    (let ((steered nil))
      (cl-letf (((symbol-function 'chat-agent-active-p) (lambda (_run) t))
                ((symbol-function 'chat-ui--steer-active-agent)
                 (lambda (content) (push content steered))))
        (setq-local chat-ui--active-agent-run 'run)
        (goto-char (point-max))
        (insert "also check the tests")
        (chat-ui-send-message))
      (should (equal steered '("also check the tests")))
      (should (equal shell-calls '("ls"))))))

(ert-deftest chat-ui-auto-refuses-a-command-that-cannot-be-default ()
  "Only repeatable commands may claim plain input."
  (chat-ui-auto-test--with-session
    (chat-ui--dispatch-command (chat-command-parse "/auto cd"))
    (should-not (chat-ui-default-command-claimed-p))
    (chat-ui--dispatch-command (chat-command-parse "/auto cmd"))
    (should (equal (chat-ui-default-command) "cmd"))))

(ert-deftest chat-ui-a-question-without-a-record-cannot-hold-plain-input ()
  "`/quick' releases the claim rather than taking it.

Taking it would be worse than the trap it replaces: every following line
would be answered and none of them written down, and nothing on screen
distinguishes an answer that was recorded from one that was not."
  (should-not (chat-ui--command-repeatable-p "quick"))
  (should-not (chat-ui--command-repeatable-p "?"))
  (should (eq (chat-ui--command-default-effect "quick") 'reset))
  (should (eq (chat-ui--command-default-effect "?") 'reset))
  ;; The recorded path may hold it, because holding it changes nothing.
  (should (chat-ui--command-repeatable-p "send"))
  (should (chat-ui--command-repeatable-p "cmd"))
  (should (chat-ui--command-repeatable-p "queue"))
  ;; A command you reach for once says nothing about the next line.
  (should-not (chat-ui--command-default-effect "cd"))
  (should-not (chat-ui--command-default-effect "pwd"))
  (should-not (chat-ui--command-default-effect "help")))

;; ------------------------------------------------------------------
;; The queue: several notes, one turn
;; ------------------------------------------------------------------

(ert-deftest chat-ui-a-queued-note-does-not-reach-the-model ()
  "Collecting is the whole point: nothing goes out until it is flushed."
  (chat-ui-auto-test--with-session
    (chat-ui--dispatch-command (chat-command-parse "/queue check the tests"))
    (should (equal (chat-ui--queue-entries) '("check the tests")))
    (should-not sent)
    (chat-ui--dispatch-command (chat-command-parse "/queue and the docs"))
    (should (equal (chat-ui--queue-entries) '("check the tests" "and the docs")))
    (should-not sent)))

(ert-deftest chat-ui-queueing-claims-plain-input ()
  "Notes come in runs, the same way shell commands do."
  (chat-ui-auto-test--with-session
    (chat-ui--dispatch-command (chat-command-parse "/queue first"))
    (should (equal (chat-ui-default-command) "queue"))
    (chat-ui--dispatch-command (chat-command-parse "second"))
    (chat-ui--dispatch-command (chat-command-parse "third"))
    (should (equal (chat-ui--queue-entries) '("first" "second" "third")))
    (should-not sent)))

(ert-deftest chat-ui-flushing-sends-one-message-and-empties-the-queue ()
  "One message rather than several: not every provider accepts two user
messages in a row, and a batch that works on some models is worse than
one that reads slightly less faithfully on all of them."
  (chat-ui-auto-test--with-session
    (chat-ui--dispatch-command (chat-command-parse "/queue first"))
    (chat-ui--dispatch-command (chat-command-parse "second"))
    (chat-ui--dispatch-command (chat-command-parse "/flush"))
    (should (= 1 (length sent)))
    (should (string-match-p "1\\. first" (car sent)))
    (should (string-match-p "2\\. second" (car sent)))
    (should-not (chat-ui--queue-entries))
    ;; And plain input is back with the model, so the next line is not
    ;; silently queued after the batch went out.
    (should-not (chat-ui-default-command-claimed-p))))

(ert-deftest chat-ui-a-queue-of-one-is-not-numbered ()
  "Numbering a list of one is noise the model has to read past."
  (chat-ui-auto-test--with-session
    (chat-ui--dispatch-command (chat-command-parse "/queue just this"))
    (chat-ui--dispatch-command (chat-command-parse "/flush"))
    (should (equal sent '("just this")))))

(ert-deftest chat-ui-flush-can-add-a-last-note ()
  "The thought that makes you send is often the last item."
  (chat-ui-auto-test--with-session
    (chat-ui--dispatch-command (chat-command-parse "/queue first"))
    (chat-ui--dispatch-command (chat-command-parse "/flush and finally this"))
    (should (string-match-p "and finally this" (car sent)))
    (should-not (chat-ui--queue-entries))))

(ert-deftest chat-ui-send-with-no-argument-flushes-the-queue ()
  "Having collected notes, `send' is the word you reach for."
  (chat-ui-auto-test--with-session
    (chat-ui--dispatch-command (chat-command-parse "/queue something"))
    (chat-ui--dispatch-command (chat-command-parse "/send"))
    (should (equal sent '("something")))))

(ert-deftest chat-ui-dropping-takes-back-the-last-note ()
  (chat-ui-auto-test--with-session
    (chat-ui--dispatch-command (chat-command-parse "/queue first"))
    (chat-ui--dispatch-command (chat-command-parse "second"))
    (chat-ui--dispatch-command (chat-command-parse "/drop"))
    (should (equal (chat-ui--queue-entries) '("first")))
    (chat-ui--dispatch-command (chat-command-parse "/drop all"))
    (should-not (chat-ui--queue-entries))))

(ert-deftest chat-ui-the-queue-survives-a-reopen ()
  "Notes are on the session.  Losing them on reopen would lose typing."
  (chat-ui-auto-test--with-session
    (chat-ui--dispatch-command (chat-command-parse "/queue remember this"))
    (chat-session-save session)
    (let ((reloaded (chat-session-load (chat-session-id session))))
      (with-temp-buffer
        (setq-local chat--current-session reloaded)
        (chat-ui-setup-buffer reloaded)
        (should (equal (chat-ui--queue-entries) '("remember this")))
        ;; A round trip through JSON hands a list of strings back as a
        ;; vector, and code that appended to it would fail here.
        (chat-ui--command-queue "and this")
        (should (equal (chat-ui--queue-entries)
                       '("remember this" "and this")))))))

(ert-deftest chat-ui-the-queue-count-is-on-screen ()
  "Text that was typed and not sent has to be visible somewhere."
  (chat-ui-auto-test--with-session
    (chat-ui--dispatch-command (chat-command-parse "/queue one"))
    (chat-ui--dispatch-command (chat-command-parse "two"))
    (should (string-match-p "queued: 2" (chat-ui--status-line session)))
    (should (string-match-p
             "queued: 2"
             (buffer-substring-no-properties (point-min) (point-max))))))

(ert-deftest chat-ui-flushing-nothing-says-so ()
  (chat-ui-auto-test--with-session
    (chat-ui--dispatch-command (chat-command-parse "/flush"))
    (should-not sent)
    (should (string-match-p
             "Nothing queued"
             (buffer-substring-no-properties (point-min) (point-max))))))

(ert-deftest chat-ui-tool-result-lines-truncate-long-results ()
  "Test oversized tool results are truncated with an omission marker."
  (let* ((chat-tool-caller-result-max-chars 20)
         (lines (chat-ui--tool-result-lines
                 '((:name "files_read" :arguments (("path" . "/tmp/x"))))
                 (list (make-string 50 ?x)))))
    (should (string-match-p "truncated, 30 chars omitted" (car lines)))))

(ert-deftest chat-ui-get-response-streaming-uses-stream-transport ()
  "Test streaming UI requests go through the agent stream transport."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-session-create "Stream Session" 'kimi))
          (chat-ui--messages-end nil)
          captured-config)
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
       (cl-letf (((symbol-function 'chat-agent-start)
                  (lambda (config)
                    (setq captured-config config)
                    nil)))
         (chat-ui--get-response-streaming)
         (should (eq (plist-get captured-config :transport) 'stream))
         (should (plist-get captured-config :on-event))
         (should (eq (plist-get captured-config :session) session)))))))

(ert-deftest chat-ui-get-response-sync-uses-sync-transport ()
  "Test non streaming UI requests go through the agent sync transport."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-session-create "Sync Session" 'kimi))
          (chat-ui--messages-end nil)
          captured-config)
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
       (cl-letf (((symbol-function 'chat-agent-start)
                  (lambda (config)
                    (setq captured-config config)
                    nil)))
         (chat-ui--get-response-sync)
         (should (eq (plist-get captured-config :transport) 'sync))
         (should (equal (plist-get captured-config :max-steps)
                        chat-ui-tool-loop-max-steps)))))))

(ert-deftest chat-ui-render-response-state-appends-only-delta-on-growth ()
  "Test growing content reuses the slot and only appends the delta."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-session-create "Render Session" 'kimi)))
     (with-temp-buffer
       (setq-local chat--current-session session)
       (chat-ui-setup-buffer session)
       (goto-char chat-ui--messages-end)
       (insert "Assistant:\n")
       (set-marker chat-ui--messages-end (point))
       (let ((content-start (copy-marker (point))))
         (chat-ui--render-response-state (current-buffer) content-start "abc" nil)
         (chat-ui--render-response-state (current-buffer) content-start "abcdef" nil)
         (should (string-match-p "abcdef" (buffer-string)))
         (should-not (string-match-p "abcabcdef" (buffer-string)))
         ;; Shrinking content falls back to a full replace.
         (chat-ui--render-response-state (current-buffer) content-start "ab" nil)
         (should (string-match-p "Assistant:\nab\n\n" (buffer-string))))))))

(ert-deftest chat-ui-fontify-markdown-lite-styles-blocks-and-emphasis ()
  "Test markdown lite fontification styles code blocks, headers, and bold."
  (with-temp-buffer
    (insert "Intro\n```elisp\n(code here)\n```\n# Title\n**bold** end\n")
    (chat-ui--fontify-markdown-lite (point-min) (point-max))
    (goto-char (point-min))
    (search-forward "(code here)")
    (should (eq (get-text-property (line-beginning-position) 'face)
                'chat-ui-code-block-face))
    (goto-char (point-min))
    (search-forward "# Title")
    (should (equal (get-text-property (line-beginning-position) 'face)
                   '(:weight bold)))
    (goto-char (point-min))
    (search-forward "bold")
    (should (eq (get-text-property (1- (point)) 'face) 'bold))))

(ert-deftest chat-ui-request-state-is-buffer-local-per-session ()
  "Test two chat buffers keep independent active run state."
  (with-temp-buffer
    (setq chat-ui--active-agent-run 'run-a)
    (setq chat-ui--active-request-handle 'handle-a)
    (with-temp-buffer
      (should-not chat-ui--active-agent-run)
      (should-not chat-ui--active-request-handle)
      (setq chat-ui--active-agent-run 'run-b))
    (should (eq chat-ui--active-agent-run 'run-a))
    (should (eq chat-ui--active-request-handle 'handle-a))))

(ert-deftest chat-ui-follow-live-output-skips-scrolled-up-window ()
  "Test a scrolled-up window is never yanked to the response edge."
  (with-temp-buffer
    (insert (make-string 4000 ?x))
    (setq chat-ui--messages-end (copy-marker (- (point-max) 4)))
    (setq chat-ui--input-overlay (copy-marker (point-max)))
    (let (moved)
      (cl-letf (((symbol-function 'get-buffer-window-list)
                 (lambda (&rest _) (list 'fake-window)))
                ((symbol-function 'window-live-p) (lambda (_) t))
                ((symbol-function 'window-point) (lambda (_) 1))
                ((symbol-function 'window-end) (lambda (&rest _) 10))
                ((symbol-function 'set-window-point)
                 (lambda (_w pos) (setq moved pos))))
        (chat-ui--follow-live-output (current-buffer))
        (should-not moved)))))

(ert-deftest chat-ui-follow-live-output-follows-edge-window ()
  "Test a window near the bottom edge follows the response edge."
  (with-temp-buffer
    (insert (make-string 4000 ?x))
    (setq chat-ui--messages-end (copy-marker (- (point-max) 4)))
    (setq chat-ui--input-overlay (copy-marker (point-max)))
    (let (moved)
      (cl-letf (((symbol-function 'get-buffer-window-list)
                 (lambda (&rest _) (list 'fake-window)))
                ((symbol-function 'window-live-p) (lambda (_) t))
                ((symbol-function 'window-point)
                 (lambda (_) (- (point-max) 40)))
                ((symbol-function 'window-end)
                 (lambda (&rest _) (point-max)))
                ((symbol-function 'set-window-point)
                 (lambda (_w pos) (setq moved pos))))
        (chat-ui--follow-live-output (current-buffer))
        (should (equal moved (marker-position chat-ui--messages-end)))))))

(ert-deftest chat-ui-follow-live-output-never-yanks-input-point ()
  "Test a window whose point is in the input area is left alone."
  (with-temp-buffer
    (insert (make-string 4000 ?x))
    (setq chat-ui--messages-end (copy-marker (- (point-max) 4)))
    (setq chat-ui--input-overlay (copy-marker (- (point-max) 3)))
    (let (moved)
      (cl-letf (((symbol-function 'get-buffer-window-list)
                 (lambda (&rest _) (list 'fake-window)))
                ((symbol-function 'window-live-p) (lambda (_) t))
                ((symbol-function 'window-point) (lambda (_) (point-max)))
                ((symbol-function 'window-end)
                 (lambda (&rest _) (point-max)))
                ((symbol-function 'set-window-point)
                 (lambda (_w pos) (setq moved pos))))
        (chat-ui--follow-live-output (current-buffer))
        (should-not moved)))))

(provide 'test-chat-ui)
;;; test-chat-ui.el ends here
