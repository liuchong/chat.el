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
        (setq-local chat-ui--live-response-start content-start)
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
  (dolist (name '("cancel" "model" "cmd" "!" "cd" "pwd" "question" "ask" "?"))
    (let ((handler (cdr (assoc name chat-ui--slash-commands))))
      (should handler)
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
              ((symbol-function 'chat-ui--command-question)
               (lambda (arg) (push (cons 'question arg) calls)))
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
                       (question . "why")
                       (cd . "/tmp")
                       (message . "/wiki-lint now")
                       (message . "!literal")
                       (message . "plain text"))
                     (nreverse calls))))))

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
