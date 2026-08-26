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
              (tool (nth 2 messages))
              (offered (plist-get (car (chat-message-tool-calls assistant)) :id))
              (referred (plist-get (chat-message-metadata tool) :tool-call-id)))
         ;; What matters is that the two halves name the same id, not what
         ;; it is spelled.  This used to assert the literal "call-1", which
         ;; is how two sides drifting onto different fallbacks went unseen:
         ;; the spelling was pinned on the path that worked.
         (should (stringp offered))
         (should (equal offered referred))
         (should (eq (chat-message-role tool) :tool))
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
  "Typing an ordinary word does not open a file completion popup.

Only reachable when the option is on, which it is not by default; bound
here because the narrowing to path-like tokens still has to hold for
anyone who turns it back on."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (chat-ui-auto-path-completion t)
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

(ert-deftest chat-ui-fence-safe-prefix-length-tracks-unfinished-blocks ()
  "A streaming cut never lands inside a block that is still arriving.

Every block now, not only fenced ones.  A table gains columns as its
rows arrive and a list item gains its hanging indent, so a cut inside
either of those froze it half-drawn for the same reason a cut inside a
fence did."
  ;; A closed fence finishes a block, so everything up to it can be kept.
  (let ((closed "```el\n(one)\n```\ntail"))
    (should (= (chat-ui--fence-safe-prefix-length closed)
               (length "```el\n(one)\n```\n"))))
  ;; An open one may still be reformatted, so nothing from it is kept.
  (should (= (chat-ui--fence-safe-prefix-length "intro\n\n```el\n(part")
             (length "intro\n\n")))
  ;; A paragraph is finished by the blank line after it, and the one
  ;; still being written is not.
  (should (= (chat-ui--fence-safe-prefix-length "done\n\nwriting")
             (length "done\n\n")))
  (should (= (chat-ui--fence-safe-prefix-length "first words") 0)))

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

(ert-deftest chat-ui-cd-dash-goes-back-and-then-forward-again ()
  "Two `cd -' in a row return to where each started, as in a shell.

`-' used to be expanded as a path, so it named a directory called `-'
under the current one and the command reported it missing."
  (chat-test-with-temp-dir
   (let ((first (file-name-as-directory (expand-file-name "one" temp-dir)))
         (second (file-name-as-directory (expand-file-name "two" temp-dir)))
         (messages nil))
     (make-directory first t)
     (make-directory second t)
     (with-temp-buffer
       (cl-letf (((symbol-function 'chat-ui--insert-system-message)
                  (lambda (text) (push text messages))))
         (setq default-directory first)
         (chat-ui--handle-shell-command (format "cd %s" second))
         (should (equal second default-directory))
         (chat-ui--handle-shell-command "cd -")
         (should (equal first default-directory))
         (chat-ui--handle-shell-command "cd -")
         (should (equal second default-directory)))))))

(ert-deftest chat-ui-cd-dash-with-no-history-reports-instead-of-moving ()
  "And leaves the working directory alone."
  (chat-test-with-temp-dir
   (let ((here (file-name-as-directory temp-dir))
         (messages nil))
     (with-temp-buffer
       (cl-letf (((symbol-function 'chat-ui--insert-system-message)
                  (lambda (text) (push text messages))))
         (setq default-directory here)
         (setq chat-shell-previous-directory nil)
         (chat-ui--handle-shell-command "cd -")
         (should (equal here default-directory))
         (should (string-match-p "OLDPWD\\|上一个" (car messages))))))))

(ert-deftest chat-ui-pushd-and-popd-walk-the-directory-stack ()
  "`pushd' remembers where it left and `popd' returns there."
  (chat-test-with-temp-dir
   (let ((first (file-name-as-directory (expand-file-name "one" temp-dir)))
         (second (file-name-as-directory (expand-file-name "two" temp-dir)))
         (messages nil))
     (make-directory first t)
     (make-directory second t)
     (with-temp-buffer
       (cl-letf (((symbol-function 'chat-ui--insert-system-message)
                  (lambda (text) (push text messages))))
         (setq default-directory first)
         (setq chat-shell-directory-stack nil)
         (chat-ui--handle-shell-command (format "pushd %s" second))
         (should (equal second default-directory))
         (chat-ui--handle-shell-command "popd")
         (should (equal first default-directory))
         (chat-ui--handle-shell-command "popd")
         (should (equal first default-directory))
         (should (string-match-p "popd\\|目录栈" (car messages))))))))

(ert-deftest chat-ui-an-exported-variable-is-there-on-the-next-line ()
  "`export' is interpreted here, so it outlives the command that set it.

Sent to the shell it would set the variable in that one subshell and be
gone by the next command."
  (chat-test-with-temp-dir
   (let ((seen nil)
         (messages nil))
     (with-temp-buffer
       (cl-letf (((symbol-function 'chat-ui--insert-system-message)
                  (lambda (text) (push text messages)))
                 ((symbol-function 'chat-ui--insert-shell-echo) #'ignore)
                 ((symbol-function 'chat-ui--insert-shell-output) #'ignore)
                 ((symbol-function 'chat-ui--execute-shell-safe-1)
                  (lambda (_command)
                    (setq seen (getenv "CHAT_TEST_EXPORTED"))
                    "")))
         (setq chat-shell-environment nil)
         (chat-ui--handle-shell-command "export CHAT_TEST_EXPORTED=yes")
         (chat-ui--handle-shell-command "printenv CHAT_TEST_EXPORTED")
         (should (equal "yes" seen))
         (chat-ui--handle-shell-command "unset CHAT_TEST_EXPORTED")
         (chat-ui--handle-shell-command "printenv CHAT_TEST_EXPORTED")
         (should-not seen))))))

(ert-deftest chat-ui-completion-does-not-arrive-uninvited ()
  "Auto completion is off, so RET sends and the buffer does not shift.

A completion UI that is open takes RET for itself, so the key that sends
becomes the key that picks a candidate.  TAB is still bound to
`completion-at-point', which is where a terminal puts it."
  (should-not chat-ui-auto-path-completion)
  (should (eq (lookup-key chat-mode-map (kbd "TAB")) 'completion-at-point)))

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

(ert-deftest chat-ui-help-takes-a-fullwidth-topic ()
  "A topic is matched against the help text, so it is folded like a name."
  (with-temp-buffer
    (setq-local chat-ui--messages-end (point-max-marker))
    (chat-ui--command-help "ａｕｔｏ")
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

(ert-deftest chat-ui-auto-takes-a-fullwidth-command-name ()
  "`/auto' reads its argument as a command name, so it folds it.

The parser cannot: the same position after `/cmd' is a shell body, where a
fullwidth character may be what was meant."
  (chat-ui-auto-test--with-session
    (chat-ui--dispatch-command (chat-command-parse "／ａｕｔｏ\u3000ｃｍｄ"))
    (should (equal (chat-ui-default-command) "cmd"))
    (chat-ui--dispatch-command (chat-command-parse "/auto ｏｆｆ"))
    (should-not (chat-ui-default-command-claimed-p))))

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

(defun chat-ui-auto-test--drawn-prompt ()
  "Return the prompt as it stands in the buffer, without properties."
  (save-excursion
    (goto-char (marker-position chat-ui--input-overlay))
    (buffer-substring-no-properties
     (line-beginning-position)
     (marker-position chat-ui--input-overlay))))

(ert-deftest chat-ui-the-prompt-says-which-command-holds-the-line ()
  "The status line is at the top; the cursor is at the bottom."
  (chat-ui-auto-test--with-session
    (should-not (string-suffix-p "cmd> " (chat-ui--input-prompt)))
    (chat-ui--dispatch-command (chat-command-parse "!ls"))
    (should (string-suffix-p "cmd> " (chat-ui--input-prompt)))
    (should (string-match-p
             "cmd> "
             (buffer-substring-no-properties (point-min) (point-max))))
    ;; And the marker still points just past it, or C-a and sending would
    ;; both be off by the width of the word.
    (should (string-suffix-p "cmd> " (chat-ui-auto-test--drawn-prompt)))
    (chat-ui--dispatch-command (chat-command-parse "/auto off"))
    (should-not (string-suffix-p "cmd> " (chat-ui--input-prompt)))
    (should-not (string-match-p
                 "cmd> "
                 (buffer-substring-no-properties (point-min) (point-max))))))

(ert-deftest chat-ui-the-prompt-names-the-model-it-will-reach ()
  "The window looking like one provider is how a question reaches another.

The name shown has to be the one the request carries, not the provider
symbol and not its display name."
  (chat-ui-auto-test--with-session
    (let ((model (plist-get (chat-llm-get-provider-config 'kimi) :model)))
      (should model)
      (should (string-match-p (regexp-quote model) (chat-ui--input-prompt)))
      ;; The provider's mark stands where a generic star would, and the
      ;; baseline command is still not announced by name.
      (should (string-prefix-p "K " (chat-ui--input-prompt)))
      (should-not (string-match-p "send" (chat-ui--input-prompt))))))

(ert-deftest chat-ui-a-shell-line-does-not-advertise-a-model ()
  "RET there does not reach one, and naming it would train the eye to skip."
  (chat-ui-auto-test--with-session
    (chat-ui--dispatch-command (chat-command-parse "!ls"))
    (let ((prompt (chat-ui--input-prompt)))
      (should (string-prefix-p "\u276F " prompt))
      (should (string-suffix-p "cmd> " prompt))
      (should-not (string-match-p
                   (regexp-quote
                    (plist-get (chat-llm-get-provider-config 'kimi) :model))
                   prompt)))))

(ert-deftest chat-ui-a-queued-line-carries-the-queue-mark ()
  "The third mode that can hold plain input."
  (chat-ui-auto-test--with-session
    (chat-ui--set-default-command "queue")
    (should (string-prefix-p "\u2261 " (chat-ui--input-prompt)))
    (should (string-suffix-p "queue> " (chat-ui--input-prompt)))))

(ert-deftest chat-ui-a-drawn-mark-changes-pixels-and-nothing-else ()
  "The invariant that makes an image safe in the prompt.

The prompt's width is measured, its bounds are computed and the input area
starts after it.  An image inserted as a character of its own would move
all three; an image displayed over a character that stays where it was
moves none.  So the test is on the text, not on the picture: whatever is
drawn, the prompt still reads as the glyph, and a terminal frame, a build
without librsvg and a yank of the line get that text with no second path
written to hand it to them."
  (let* ((image '(image :type svg :data "<svg/>"))
         (plain (chat-ui--prompt-mark "D" 'chat-mark-brand-deepseek))
         (drawn (chat-ui--prompt-mark "D" 'chat-mark-brand-deepseek image)))
    (should (equal "D " (substring-no-properties drawn)))
    (should (equal (substring-no-properties plain)
                   (substring-no-properties drawn)))
    (should (equal image (get-text-property 0 'display drawn)))
    ;; One `display' property spanning a run draws one image for the whole
    ;; run, so covering the space too would replace it and set the badge
    ;; against the model name.
    (should-not (get-text-property 1 'display drawn))
    ;; The properties the prompt is protected and found by are still on
    ;; every character of it, including the one carrying the image.
    (should (get-text-property 0 'read-only drawn))
    (should (get-text-property 1 'read-only drawn))))

(ert-deftest chat-ui-a-mode-with-no-mark-still-gets-a-prompt ()
  "An unmarked command is a supported state, not an error."
  (chat-ui-auto-test--with-session
    (chat-ui--set-default-command "drop")
    (should (equal "drop> " (chat-ui--input-prompt)))))

(ert-deftest chat-ui-an-undisplayable-mark-leaves-a-usable-prompt ()
  "On a frame that cannot draw the glyph, the prompt is the old one."
  (chat-ui-auto-test--with-session
    (cl-letf (((symbol-function 'char-displayable-p) (lambda (_c) nil)))
      (chat-ui--dispatch-command (chat-command-parse "!ls"))
      (should (equal "cmd> " (chat-ui--input-prompt)))
      (chat-ui--set-default-command nil)
      ;; The provider mark goes too, and the model name is still there.
      (should (equal (concat (plist-get (chat-llm-get-provider-config 'kimi)
                                        :model)
                             "> ")
                     (chat-ui--input-prompt))))))

(ert-deftest chat-ui-a-long-model-name-is-truncated-by-columns ()
  "Counted in columns, or a CJK name is measured at half its width."
  (chat-ui-auto-test--with-session
    (cl-letf (((symbol-function 'chat-llm-get-provider-config)
               (lambda (_provider) (list :name "Wide" :model "模型名字很长的那个"))))
      (let* ((chat-ui-prompt-model-width 8)
             (prompt (chat-ui--input-prompt))
             (shown (string-remove-suffix "> " (substring prompt 2))))
        (should (<= (string-width shown) 8))
        ;; And what was cut is still readable on hover.
        (should (string-match-p
                 "模型名字很长的那个"
                 (or (get-text-property 2 'help-echo prompt) "")))))))

(defmacro chat-ui-auto-test--with-providers (providers &rest body)
  "Evaluate BODY as though exactly PROVIDERS had a key configured.

Stated rather than inherited: several tests elsewhere register providers
with a key into the global registry and never take them out, so the real
answer during a full run depends on what ran first."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'chat-llm-configured-providers)
              (lambda () ,providers)))
     ,@body))

(ert-deftest chat-ui-only-configured-providers-are-offered ()
  "chat.el registers sixteen vendors; a machine reaches the ones with a key.

The register is a catalogue, not a choice, and the difference is what
someone sees when they go to switch."
  (chat-ui-auto-test--with-session
    (chat-ui-auto-test--with-providers '(kimi deepseek)
      (let ((offered (chat-ui--offered-providers)))
        (should (equal '(kimi deepseek) offered))
        (should-not (memq 'openai offered))
        (should-not (memq 'gemini offered))))
    ;; Sensed, not declared: a key appearing counts immediately.
    (chat-ui-auto-test--with-providers '(kimi deepseek claude)
      (should (memq 'claude (chat-ui--offered-providers))))))

(ert-deftest chat-ui-the-session-provider-is-offered-even-without-a-key ()
  "A session sitting on one has to see where it is and be able to leave."
  (chat-ui-auto-test--with-session
    (chat-ui-auto-test--with-providers '(deepseek)
      (let ((offered (chat-ui--offered-providers)))
        (should (memq 'kimi offered))
        (should (memq 'deepseek offered))
        ;; And it is not listed twice once it does have a key.
        (chat-ui-auto-test--with-providers '(kimi deepseek)
          (should (equal '(kimi deepseek) (chat-ui--offered-providers))))))))

(ert-deftest chat-ui-the-model-is-clickable-only-when-there-is-a-choice ()
  "A `mouse-face' over a menu of one promises a choice that does not exist."
  (chat-ui-auto-test--with-session
    (chat-ui-auto-test--with-providers '(kimi deepseek)
      (let ((prompt (chat-ui--input-prompt)))
        (should (get-text-property 2 'keymap prompt))
        (should (get-text-property 2 'mouse-face prompt))))
    (chat-ui-auto-test--with-providers '(kimi)
      (let ((prompt (chat-ui--input-prompt)))
        (should-not (get-text-property 2 'keymap prompt))
        (should-not (get-text-property 2 'mouse-face prompt))))
    ;; Nothing configured at all is also not a choice.
    (chat-ui-auto-test--with-providers nil
      (let ((prompt (chat-ui--input-prompt)))
        (should-not (get-text-property 2 'keymap prompt))))))

(ert-deftest chat-ui-the-input-does-not-inherit-the-mouse-binding ()
  "A keymap that spread into the input would rebind clicks in the message."
  (chat-ui-auto-test--with-session
    (goto-char (point-max))
    (insert-and-inherit "hello")
    (should-not (get-text-property (marker-position chat-ui--input-overlay)
                                   'keymap))))

(ert-deftest chat-ui-the-mark-is-as-protected-as-the-rest-of-the-prompt ()
  "The mark is part of the prompt, not decoration sitting beside it."
  (chat-ui-auto-test--with-session
    (chat-ui--dispatch-command (chat-command-parse "!ls"))
    (let ((start (car (chat-ui--input-prompt-bounds))))
      (should (get-text-property start 'chat-ui-prompt))
      (should (get-text-property start 'read-only))
      ;; And the bounds cover the mark, so recovery redraws all of it.
      (should (string-prefix-p
               "\u276F " (buffer-substring-no-properties
                          start (marker-position chat-ui--input-overlay)))))))

(ert-deftest chat-ui-switching-provider-goes-through-the-command-that-checks ()
  "Not by setting the session field, which would skip its refusals."
  (chat-ui-auto-test--with-session
    (chat-ui-auto-test--with-providers '(kimi claude)
     (cl-letf (((symbol-function 'display-popup-menus-p) (lambda () nil))
               ((symbol-function 'completing-read)
                (lambda (_prompt collection &rest _)
                  (seq-find (lambda (label) (string-prefix-p "Claude" label))
                            collection))))
      (chat-ui-switch-model)
      (should (eq 'claude (chat-session-model-id chat--current-session)))
      ;; And the prompt says so, or the two places that name the model
      ;; would disagree.
      (should (string-match-p
               (regexp-quote (plist-get (chat-llm-get-provider-config 'claude)
                                        :model))
               (chat-ui-auto-test--drawn-prompt)))))))

(ert-deftest chat-ui-the-popup-menu-is-shaped-the-way-emacs-expects ()
  "Batch mode never draws one, so the shape has to be asserted instead.

A malformed pane would fail only on a real click, in a build no test
runs."
  (chat-ui-auto-test--with-session
   (chat-ui-auto-test--with-providers '(kimi claude)
    (let ((menu nil))
      (cl-letf (((symbol-function 'display-popup-menus-p) (lambda () t))
                ((symbol-function 'x-popup-menu)
                 (lambda (_position m)
                   (setq menu m)
                   ;; Answer with a real item's value, the way a click
                   ;; does, so the pair has to survive the round trip.
                   (cdr (car (cdr (car (cdr m))))))))
        (chat-ui-switch-model '(mouse-1 (nil . 1)))
        ;; (TITLE (PANE-TITLE (LABEL . VALUE) ...)) with one pane per
        ;; vendor, and each value the (PROVIDER . MODEL) pair, so the
        ;; click hands back both halves of the answer.
        (should (stringp (car menu)))
        (should (>= (length menu) 3))
        (dolist (pane (cdr menu))
          (should (stringp (car pane)))
          (dolist (item (cdr pane))
            (should (stringp (car item)))
            (should (symbolp (car (cdr item))))
            (should (stringp (cdr (cdr item))))))
        ;; Whichever vendor came first, both halves of its item landed.
        (let ((provider (chat-session-model-id chat--current-session)))
          (should (memq provider '(kimi claude)))
          (should (member (chat-session-model-name chat--current-session)
                          (chat-llm-provider-models provider)))))))))

(ert-deftest chat-ui-the-menu-groups-models-under-their-vendor ()
  "Vendor and model are two questions; a flat list answers neither.

A provider list read as one vendor per protocol variant and showed no
models at all, which is how four Kimi models and three DeepSeek ones were
invisible behind two entries that looked like two companies."
  (chat-ui-auto-test--with-session
   (chat-ui-auto-test--with-providers '(kimi claude)
    (let ((groups (chat-ui--model-choices)))
      (should (= 2 (length groups)))
      (dolist (group groups)
        (should (stringp (car group)))
        (should (cdr group)))
      ;; Two vendors, one model each in the stub, so the count is the
      ;; number of choices rather than the number of vendors.
      (should (= 2 (chat-ui--model-choice-count)))))))

(ert-deftest chat-ui-a-vendor-with-two-protocols-appears-once ()
  "The protocol is not what someone choosing a model is choosing.

Kimi Code registers twice, once per protocol.  Listing both put \"Kimi
Code\" and \"Kimi Code (Anthropic)\" side by side as if they were two
companies."
  (chat-ui-auto-test--with-session
   (chat-ui-auto-test--with-providers '(kimi-code kimi-code-anthropic)
    ;; On this vendor already, so the session contributes no second group.
    (chat-set-model 'kimi-code)
    (let ((groups (chat-ui--model-choices)))
      (should (= 1 (length groups)))
      ;; The group is the vendor, so the protocol's parenthetical is not
      ;; part of its heading.
      (should (equal "Kimi Code" (car (car groups))))
      ;; And every model reached through the primary provider.
      (dolist (item (cdr (car groups)))
        (should (eq 'kimi-code (car (cdr item)))))
      (should (equal (chat-llm-provider-models 'kimi-code)
                     (mapcar (lambda (item) (cdr (cdr item)))
                             (cdr (car groups)))))))))

(ert-deftest chat-ui-the-other-protocol-is-still-reachable-by-name ()
  "Kept out of the menu, not out of reach: it is a different code path."
  (chat-ui-auto-test--with-session
   (should (chat-llm-get-provider-config 'kimi-code-anthropic))
   (chat-set-model 'kimi-code-anthropic "k3")
   (should (eq 'kimi-code-anthropic
               (chat-session-model-id chat--current-session)))
   (should (equal "k3" (chat-session-model-name chat--current-session)))))

(ert-deftest chat-ui-the-menu-marks-where-the-session-already-is ()
  "The first question on opening the menu is where you already are."
  (chat-ui-auto-test--with-session
   (chat-set-model 'kimi-code "k3-256k")
   (let* ((groups (chat-ui--model-choices))
          (marked (seq-filter
                   (lambda (item) (string-prefix-p "*" (car item)))
                   (apply #'append (mapcar #'cdr groups)))))
     (should (= 1 (length marked)))
     (should (equal "k3-256k" (cdr (cdr (car marked))))))))

(ert-deftest chat-ui-the-prompt-names-the-model-the-session-pinned ()
  "Not the provider's default, which is a different answer once pinned.

A prompt naming something other than what the request carries stops
preventing mistakes and starts causing them."
  (chat-ui-auto-test--with-session
   (chat-set-model 'kimi-code "k3-256k")
   (let ((prompt (chat-ui-auto-test--drawn-prompt)))
     (should (string-match-p "k3-256k" prompt))
     ;; And not the default it was pinned away from.
     (should-not
      (string-match-p
       (regexp-quote (plist-get (chat-llm-get-provider-config 'kimi-code)
                                :model))
       prompt)))))

(ert-deftest chat-ui-an-unpinned-session-follows-the-provider-default ()
  "nil is a value, not an absence: it means \"whatever the default is\".

Writing the default into the session would freeze one snapshot of a
setting the configuration may change -- the registry bug, moved."
  (chat-ui-auto-test--with-session
   (chat-set-model 'kimi-code)
   (should (null (chat-session-model-name chat--current-session)))
   (should (equal (plist-get (chat-llm-get-provider-config 'kimi-code) :model)
                  (chat-ui--session-model-name)))))

(ert-deftest chat-ui-switching-vendor-drops-the-old-vendor-model ()
  "A model id belongs to the vendor that serves it.

Carried over, `k3' would be sent to DeepSeek, which can only refuse it."
  (chat-ui-auto-test--with-session
   (chat-set-model 'kimi-code "k3")
   (chat-set-model 'deepseek)
   (should (null (chat-session-model-name chat--current-session)))))

(ert-deftest chat-ui-a-model-the-provider-does-not-serve-is-refused ()
  "And the session is left where it was, not half-moved."
  (chat-ui-auto-test--with-session
   (chat-set-model 'kimi-code "k3")
   (should-error (chat-set-model 'deepseek "k3") :type 'user-error)
   (should (eq 'kimi-code (chat-session-model-id chat--current-session)))
   (should (equal "k3" (chat-session-model-name chat--current-session)))))

(defun chat-ui-auto-test--request-options ()
  "Return the request options a run would hand the transport."
  (let ((options nil))
    (cl-letf (((symbol-function 'chat-agent-start)
               (lambda (config)
                 (setq options (plist-get config :request-options))
                 nil)))
      (chat-ui--start-agent-run 'stream))
    options))

(ert-deftest chat-ui-the-pinned-model-is-what-the-request-carries ()
  "The point of pinning.  Read out of the same options the transport gets."
  (chat-ui-auto-test--with-session
   (chat-set-model 'kimi-code "k3-256k")
   (should (equal "k3-256k"
                  (plist-get (chat-ui-auto-test--request-options) :model))))
  ;; An unpinned session says nothing, leaving the choice to the provider
  ;; at request time -- including after its default changes.
  (chat-ui-auto-test--with-session
   (chat-set-model 'kimi-code)
   (should-not (plist-member (chat-ui-auto-test--request-options) :model))))

(ert-deftest chat-ui-switching-provider-is-refused-mid-response ()
  "The reply would come back from a provider that was never asked."
  (chat-ui-auto-test--with-session
   (chat-ui-auto-test--with-providers '(kimi claude)
    (cl-letf (((symbol-function 'display-popup-menus-p) (lambda () nil))
              ((symbol-function 'completing-read)
               (lambda (_prompt collection &rest _) (car collection)))
              ((symbol-function 'chat-ui--response-active-p) (lambda () t)))
      (should-error (chat-ui-switch-model) :type 'user-error)))))

(ert-deftest chat-ui-switching-provider-says-so-when-there-is-nothing-to-pick ()
  "One provider is not a menu."
  (chat-ui-auto-test--with-session
   (chat-ui-auto-test--with-providers '(kimi)
    (chat-ui-switch-model)
    (should (eq 'kimi (chat-session-model-id chat--current-session))))))

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

(ert-deftest chat-ui-the-prompt-cannot-be-backspaced-away ()
  "The prompt sits where the reader types, so it has to defend itself."
  (chat-ui-auto-test--with-session
    (chat-ui--dispatch-command (chat-command-parse "!ls"))
    (goto-char (point-max))
    (should-error (delete-char -1) :type 'text-read-only)
    (should (string-suffix-p "cmd> " (chat-ui-auto-test--drawn-prompt)))))

(ert-deftest chat-ui-typing-after-the-prompt-is-not-protected-too ()
  "Protection that spread to the input would make the input unusable."
  (chat-ui-auto-test--with-session
    (chat-ui--dispatch-command (chat-command-parse "!ls"))
    (goto-char (point-max))
    (insert-and-inherit "echo hi")
    (should (equal "echo hi" (chat-ui--input-text)))
    ;; Clearing what was typed must not be refused either.
    (chat-ui--clear-input (marker-position chat-ui--input-overlay) (point-max))
    (should (equal "" (chat-ui--input-text)))))

(ert-deftest chat-ui-typing-after-the-prompt-does-not-take-its-colour ()
  "The prompt is coloured to stand out; input wearing that colour undoes it."
  (chat-ui-auto-test--with-session
    (chat-ui--dispatch-command (chat-command-parse "!ls"))
    (goto-char (point-max))
    (insert-and-inherit "echo hi")
    (should-not (get-text-property (marker-position chat-ui--input-overlay)
                                  'face))))

(ert-deftest chat-ui-the-prompt-cannot-be-deleted-from-in-front-of-it ()
  "Walking to it with the arrow keys and pressing delete is the other way in."
  (chat-ui-auto-test--with-session
    (chat-ui--dispatch-command (chat-command-parse "!ls"))
    (goto-char (marker-position chat-ui--input-overlay))
    (backward-char 3)
    (should-error (delete-char 1) :type 'text-read-only)
    (should-error (kill-line) :type 'text-read-only)
    (should (string-suffix-p "cmd> " (chat-ui-auto-test--drawn-prompt)))))

(ert-deftest chat-ui-claiming-the-line-leaves-the-cursor-after-the-prompt ()
  "`/cmd ls' widens the prompt under the cursor, which must not overtake it."
  (chat-ui-auto-test--with-session
    (goto-char (point-max))
    (chat-ui--dispatch-command (chat-command-parse "/cmd ls"))
    (should (= (point) (marker-position chat-ui--input-overlay)))
    ;; And what is typed next lands in the input, not in front of the prompt.
    (insert-and-inherit "x")
    (should (equal "x" (chat-ui--input-text)))))

(ert-deftest chat-ui-releasing-the-line-leaves-the-cursor-after-the-prompt ()
  "The prompt narrows on the way back out, and the cursor followed it out."
  (chat-ui-auto-test--with-session
    (chat-ui--dispatch-command (chat-command-parse "!ls"))
    (goto-char (point-max))
    (chat-ui--dispatch-command (chat-command-parse "/send hello"))
    (should (= (point) (marker-position chat-ui--input-overlay)))))

(ert-deftest chat-ui-a-redrawn-prompt-keeps-the-cursor-where-it-was-typing ()
  "Point mid-word must stay mid-word, not jump to either end of the input."
  (chat-ui-auto-test--with-session
    (goto-char (point-max))
    (insert "half a thought")
    (backward-char 7)
    (let ((offset (- (point) (marker-position chat-ui--input-overlay))))
      (chat-ui--set-default-command "cmd")
      (chat-ui--render-input-prompt)
      (should (= offset (- (point) (marker-position chat-ui--input-overlay)))))))

(ert-deftest chat-ui-a-reader-above-the-input-is-not-pulled-down-to-it ()
  "Redrawing the prompt must not move a cursor that was not in the input."
  (chat-ui-auto-test--with-session
    (goto-char (point-min))
    (let ((where (point)))
      (chat-ui--set-default-command "cmd")
      (chat-ui--render-input-prompt)
      (should (= where (point))))))

(ert-deftest chat-ui-a-lost-prompt-comes-back-on-the-next-send ()
  "A prompt that goes missing used to stay missing for the life of the buffer.

Nothing on the send path drew it, so whatever ate it -- a completion UI
replacing a region, a kill that reached too far -- left a buffer with no
prompt and no way back short of reopening the session."
  (chat-ui-auto-test--with-session
    (chat-ui--dispatch-command (chat-command-parse "!ls"))
    (let ((end (marker-position chat-ui--input-overlay))
          (inhibit-read-only t))
      (goto-char end)
      (delete-region (line-beginning-position) end))
    (should (equal "" (buffer-substring-no-properties
                       (line-beginning-position)
                       (marker-position chat-ui--input-overlay))))
    (goto-char (point-max))
    (insert "echo hi")
    (chat-ui-send-message)
    (should (string-suffix-p "cmd> " (chat-ui-auto-test--drawn-prompt)))
    ;; The repair must not have swallowed what was typed.
    (should (equal (car shell-calls) "echo hi"))))

(ert-deftest chat-ui-half-a-prompt-is-repaired-rather-than-doubled ()
  "Recovery keys off what the prompt is, not off how wide it should be."
  (chat-ui-auto-test--with-session
    (chat-ui--dispatch-command (chat-command-parse "!ls"))
    (let ((end (marker-position chat-ui--input-overlay))
          (inhibit-read-only t))
      (delete-region (- end 2) end))
    (chat-ui--render-input-prompt)
    (should (string-suffix-p "cmd> " (chat-ui-auto-test--drawn-prompt)))))

(ert-deftest chat-ui-sending-leaves-the-prompt-alone-when-it-is-intact ()
  "The common case must not churn the buffer on every RET."
  (chat-ui-auto-test--with-session
    (chat-ui--dispatch-command (chat-command-parse "!ls"))
    (let ((before (marker-position chat-ui--input-overlay)))
      (goto-char (point-max))
      (insert "echo hi")
      (chat-ui-send-message)
      (should (= before (marker-position chat-ui--input-overlay)))
      (should (string-suffix-p "cmd> " (chat-ui-auto-test--drawn-prompt))))))

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

(ert-deftest chat-ui-dropping-all-accepts-a-fullwidth-keyword ()
  "`all' is a keyword the command compares against, not text to keep."
  (chat-ui-auto-test--with-session
    (chat-ui--dispatch-command (chat-command-parse "/queue first"))
    (chat-ui--dispatch-command (chat-command-parse "second"))
    (chat-ui--dispatch-command (chat-command-parse "／ｄｒｏｐ\u3000ａｌｌ"))
    (should-not (chat-ui--queue-entries))))

(ert-deftest chat-ui-a-queued-note-keeps-its-fullwidth-characters ()
  "A note is data.  Folding it would rewrite what the user is sending."
  (chat-ui-auto-test--with-session
    (chat-ui--dispatch-command (chat-command-parse "/queue 搜索 ＡＢＣ"))
    (should (equal (chat-ui--queue-entries) '("搜索 ＡＢＣ")))))

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

(ert-deftest chat-ui-the-waiting-state-is-drawn-before-the-transport ()
  "The reader has to see something between RET and the request going out.

Nothing painted a frame there: the question was in the buffer unpainted
and the live line waited on a refresh timer a second away, so both
arrived together once the request was already on the wire -- which reads
as the send having waited for it."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-session-create "Waiting" 'kimi))
          (drawn-before-preparing nil))
     (chat-session-add-message
      session
      (make-chat-message :id "user-1" :role :user :content "Hello"
                         :timestamp (current-time)))
     (with-temp-buffer
       (setq-local chat--current-session session)
       (chat-ui-setup-buffer session)
       (cl-letf* ((prepare (symbol-function 'chat-ui--prepare-messages-with-tools))
                  ((symbol-function 'chat-ui--prepare-messages-with-tools)
                   (lambda (messages)
                     (setq drawn-before-preparing
                           (buffer-substring-no-properties (point-min) (point-max)))
                     (funcall prepare messages)))
                  ((symbol-function 'chat-agent-start) (lambda (_config) nil)))
         (chat-ui--get-response-streaming))
       ;; The question and a waiting line naming the transport, both on
       ;; screen before any of the request work has been done.
       (should (string-match-p "You:\nHello" drawn-before-preparing))
       (should (string-match-p "Preparing stream request"
                               drawn-before-preparing))))))

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

(ert-deftest chat-ui-insertion-goes-through-the-one-renderer ()
  "Styling arrives with the text rather than from a pass over it after.

The pass that used to add headings and bold ran in one place, at the end
of a turn, so the next redraw -- a fold, a reopen, an appended message --
dropped what it had added.  There is nothing to re-run now: the styling
is a property of the rendering, and every path renders from the same
recorded Markdown."
  (with-temp-buffer
    (chat-ui--insert-formatted-response
     "## Title\n\nA **bold** word.\n\n```elisp\n(code here)\n```")
    (goto-char (point-min))
    (search-forward "Title")
    (should (memq 'chat-markdown-heading-1
                  (let ((face (get-text-property (1- (point)) 'face)))
                    (if (listp face) face (list face)))))
    (goto-char (point-min))
    (search-forward "bold")
    (should (memq 'bold (let ((face (get-text-property (1- (point)) 'face)))
                          (if (listp face) face (list face)))))
    (goto-char (point-min))
    (search-forward "(code here)")
    (should (memq 'chat-code-block-face
                  (let ((face (get-text-property (line-beginning-position)
                                                 'face)))
                    (if (listp face) face (list face)))))
    ;; And the buffer still holds what the model wrote, hashes and stars
    ;; included, so copying a reply gives back its source.
    (should (string-match-p "## Title" (buffer-string)))
    (should (string-match-p "\\*\\*bold\\*\\*" (buffer-string)))))

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
