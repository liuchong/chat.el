;;; chat-ui.el --- UI components for chat.el -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;; Author: chat.el contributors
;; Keywords: chat, ui

;; This file is not part of GNU Emacs.

;;; Commentary:

;; This module provides UI components and interaction for chat sessions.

;;; Code:

(require 'chat-session)
(require 'chat-llm)
(require 'chat-stream)
(require 'chat-tool-forge-ai)
(require 'chat-tool-caller)
(require 'chat-context)
(require 'chat-log)

;; ------------------------------------------------------------------
;; Chat Buffer Management
;; ------------------------------------------------------------------

(defvar chat-ui--input-overlay nil
  "Overlay for the input area in chat buffer.")

(defvar chat-ui--messages-end nil
  "Marker for end of messages area.")

(defvar chat-ui--active-request-handle nil
  "Currently active non streaming request handle.")

(defun chat-ui--response-active-p ()
  "Return non nil when a response is already in progress."
  (or chat-ui--active-request-handle
      (and chat-ui--active-stream-process
           (process-live-p chat-ui--active-stream-process))))

(defun chat-ui-setup-buffer (session)
  "Setup chat buffer for SESSION."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (propertize (format "═══ %s ═══\n" (chat-session-name session))
                       'face 'header-line))
    (insert (propertize (format "Model: %s\n\n" (chat-session-model-id session))
                       'face 'shadow))
    (dolist (msg (chat-session-messages session))
      (chat-ui--insert-message msg))
    (setq chat-ui--messages-end (point-marker))
    (chat-ui--setup-input-area)))

(defun chat-ui--insert-message (msg)
  "Insert message MSG into buffer."
  (let* ((role (chat-message-role msg))
         (content (chat-message-content msg))
         (role-face (pcase role
                      (:user 'font-lock-keyword-face)
                      (:assistant 'font-lock-function-name-face)
                      (:system 'font-lock-comment-face)
                      (_ 'default)))
         (role-name (pcase role
                      (:user "You")
                      (:assistant "Assistant")
                      (:system "System")
                      (_ (symbol-name role)))))
    (insert (propertize (format "%s:\n" role-name) 'face role-face))
    (insert content)
    (insert "\n\n")))

(defun chat-ui--setup-input-area ()
  "Setup the input area at bottom of buffer."
  (goto-char (point-max))
  (insert (propertize "───\n" 'face 'shadow))
  (insert "> ")
  (setq chat-ui--input-overlay (point-marker)))

;; ------------------------------------------------------------------
;; Message Sending
;; ------------------------------------------------------------------

(defun chat-ui-send-message ()
  "Send message from input area."
  (interactive)
  (when chat--current-session
    (if (chat-ui--response-active-p)
        (message "A response is already in progress. Cancel it before sending another message.")
      (let* ((input-start (marker-position chat-ui--input-overlay))
             (input-end (point-max))
             (content (string-trim (buffer-substring-no-properties input-start input-end))))
        ;; Check for empty message
        (if (string-empty-p content)
            (message "Cannot send empty message")
          ;; Clear input
          (delete-region input-start input-end)
          (goto-char input-start)
          ;; Check for special prefixes and commands
          (cond
           ;; Cancel current request
           ((string-equal "/cancel" content)
            (chat-ui-cancel-response)
            (message "Request cancelled."))
           ;; Shell command with ! prefix
           ((string-prefix-p "!" content)
            (chat-ui--handle-shell-command (substring content 1)))
           ;; Direct AI query with ? prefix
           ((string-prefix-p "?" content)
            (chat-ui--handle-direct-query (substring content 1)))
           ;; Tool creation request
           ((chat-tool-forge-ai--tool-request-p content)
            (chat-ui--handle-tool-creation content))
           ;; Normal message flow
           (t
            (let ((user-msg (make-chat-message
                            :id (format "msg-%s" (random 10000))
                            :role :user
                            :content content
                            :timestamp (current-time))))
              (chat-session-add-message chat--current-session user-msg)
              ;; Insert in buffer
              (save-excursion
                (goto-char chat-ui--messages-end)
                (chat-ui--insert-message user-msg)
                (set-marker chat-ui--messages-end (point)))
              ;; Get AI response
              (chat-ui--get-response))))))))

(defun chat-ui--prepare-messages-with-tools (messages)
  "Prepare message list with tool calling system prompt."
  (if (not chat-tool-caller-enabled)
      (progn
        (chat-log "[TOOLS] Tool calling disabled, using original messages")
        messages)
    (let ((system-prompt (chat-tool-caller-build-system-prompt
                          "You are a helpful AI assistant.")))
      (chat-log "[TOOLS] System prompt: %s" system-prompt)
      (chat-log "[TOOLS] Adding system message to %d user messages" (length messages))
      (cons (make-chat-message
             :id "system-tools"
             :role :system
             :content system-prompt
             :timestamp (current-time))
            messages))))

(defun chat-ui--format-tool-results (tool-results)
  "Format TOOL-RESULTS for display."
  (when tool-results
    (mapconcat #'identity tool-results "\n")))

(defun chat-ui--tool-result-lines (tool-calls tool-results)
  "Format TOOL-CALLS and TOOL-RESULTS into readable lines."
  (let (lines)
    (while (and tool-calls tool-results)
      (let* ((call (car tool-calls))
             (name (plist-get call :name))
             (arguments (plist-get call :arguments))
             (result (string-trim-right (or (car tool-results) ""))))
        (push (format "- %s %S => %s" name arguments result) lines))
      (setq tool-calls (cdr tool-calls))
      (setq tool-results (cdr tool-results)))
    (nreverse lines)))

(defun chat-ui--tool-followup-message (tool-calls tool-results)
  "Build a follow-up system message from TOOL-CALLS and TOOL-RESULTS."
  (concat
   "Tool results from the previous step:\n"
   (mapconcat #'identity
              (chat-ui--tool-result-lines tool-calls tool-results)
              "\n")
   "\nUse these results to continue helping.\n"
   "If a tool result says approval denied, do not retry the same risky tool immediately.\n"
   "If another tool is needed, call one tool as JSON.\n"
   "Otherwise answer normally."))

(defun chat-ui--merge-processed-results (base extra)
  "Merge processed tool data from BASE and EXTRA."
  (list :content (plist-get extra :content)
        :tool-calls (append (plist-get base :tool-calls)
                            (plist-get extra :tool-calls))
        :tool-results (append (plist-get base :tool-results)
                              (plist-get extra :tool-results))))

(defcustom chat-ui-tool-loop-max-steps 100
  "Maximum number of tool loop follow-up requests."
  :type 'integer
  :group 'chat)

(defun chat-ui--resolve-tool-loop (model messages processed raw-request raw-response
                                         &optional depth session)
  "Continue tool use for MODEL with MESSAGES until a final answer appears."
  (let ((step (or depth 0)))
    (if (or (null (plist-get processed :tool-calls))
            (>= step chat-ui-tool-loop-max-steps))
        (list :processed processed
              :raw-request raw-request
              :raw-response raw-response)
      (let* ((followup-message
              (make-chat-message
               :id (format "tool-step-%s-%s" (random 10000) step)
               :role :system
               :content (chat-ui--tool-followup-message
                         (plist-get processed :tool-calls)
                         (plist-get processed :tool-results))
               :timestamp (current-time)))
             ;; Avoid duplicate messages by checking ID
             (next-messages (if (chat-ui--message-exists-p followup-message messages)
                                messages
                              (append messages (list followup-message))))
             (next-result (chat-llm-request model next-messages '(:temperature 0.7)))
             (next-processed
              (chat-tool-caller-process-response-data
               (plist-get next-result :content)
               session))
             (resolved
              (chat-ui--resolve-tool-loop
               model
               next-messages
               next-processed
               (plist-get next-result :raw-request)
               (plist-get next-result :raw-response)
               (1+ step)
               session)))
        (list :processed
              (chat-ui--merge-processed-results
               processed
               (plist-get resolved :processed))
              :raw-request (plist-get resolved :raw-request)
              :raw-response (plist-get resolved :raw-response))))))

(defun chat-ui--message-exists-p (message messages)
  "Check if MESSAGE (by ID) already exists in MESSAGES list."
  (let ((msg-id (chat-message-id message)))
    (cl-some (lambda (m) (equal (chat-message-id m) msg-id))
             messages)))

(defun chat-ui--resolve-tool-loop-async (model messages processed raw-request raw-response
                                               callback error-callback &optional depth session)
  "Resolve tool use asynchronously before calling CALLBACK."
  (let ((step (or depth 0)))
    (if (or (null (plist-get processed :tool-calls))
            (>= step chat-ui-tool-loop-max-steps))
        (funcall callback
                 (list :processed processed
                       :raw-request raw-request
                       :raw-response raw-response))
      (let* ((followup-message
              (make-chat-message
               :id (format "tool-step-%s-%s" (random 10000) step)
               :role :system
               :content (chat-ui--tool-followup-message
                         (plist-get processed :tool-calls)
                         (plist-get processed :tool-results))
               :timestamp (current-time)))
             (next-messages (if (chat-ui--message-exists-p followup-message messages)
                                messages
                              (append messages (list followup-message)))))
        (setq chat-ui--active-request-handle
              (chat-llm-request-async
               model
               next-messages
               (lambda (next-result)
                 (let ((next-processed
                        (chat-tool-caller-process-response-data
                         (plist-get next-result :content)
                         session)))
                   (chat-ui--resolve-tool-loop-async
                    model
                    next-messages
                    next-processed
                    (plist-get next-result :raw-request)
                    (plist-get next-result :raw-response)
                    (lambda (resolved)
                      (funcall callback
                               (list :processed
                                     (chat-ui--merge-processed-results
                                      processed
                                      (plist-get resolved :processed))
                                     :raw-request (plist-get resolved :raw-request)
                                     :raw-response (plist-get resolved :raw-response))))
                    error-callback
                    (1+ step)
                    session)))
               error-callback
               '(:temperature 0.7)))))))

(defun chat-ui--finalize-response (session msg-id ui-buffer content-start processed
                                           &optional raw-request raw-response)
  "Render PROCESSED response and persist it for SESSION."
  (let* ((content (or (plist-get processed :content) ""))
         (tool-calls (plist-get processed :tool-calls))
         (tool-results (plist-get processed :tool-results))
         (tool-summary (chat-ui--format-tool-results tool-results))
         (history-content (if (and (string-blank-p content) tool-summary)
                              tool-summary
                            content)))
    (when (buffer-live-p ui-buffer)
      (with-current-buffer ui-buffer
        (save-excursion
          (let ((inhibit-read-only t))
            (delete-region content-start chat-ui--messages-end)
            (goto-char content-start)
            (insert content)
            (when tool-summary
              (when (> (length content) 0)
                (insert "\n"))
              (insert (format "[Tools used: %s]" tool-summary)))
            (insert "\n\n")
            (set-marker chat-ui--messages-end (point))))))
    (chat-session-add-message
     session
     (make-chat-message
      :id msg-id
      :role :assistant
      :content history-content
      :timestamp (current-time)
      :tool-calls tool-calls
      :tool-results tool-results
      :raw-request raw-request
      :raw-response raw-response))
    (chat-log "[UI] Response saved to session")))

(defun chat-ui--render-error (ui-buffer error-message)
  "Render ERROR-MESSAGE in UI-BUFFER."
  (setq chat-ui--active-request-handle nil)
  (when (buffer-live-p ui-buffer)
    (with-current-buffer ui-buffer
      (save-excursion
        (goto-char chat-ui--messages-end)
        (insert (format "[Error: %s]" error-message))
        (insert "\n\n")
        (set-marker chat-ui--messages-end (point))))))

(defun chat-ui--handle-response-success (session msg-id ui-buffer content-start model messages result)
  "Handle successful RESULT for SESSION in UI-BUFFER."
  (let ((processed (chat-tool-caller-process-response-data
                    (plist-get result :content)
                    session)))
    (chat-ui--resolve-tool-loop-async
     model
     messages
     processed
     (plist-get result :raw-request)
     (plist-get result :raw-response)
     (lambda (resolved)
       (setq chat-ui--active-request-handle nil)
       (chat-ui--finalize-response
        session
        msg-id
        ui-buffer
        content-start
        (plist-get resolved :processed)
        (plist-get resolved :raw-request)
        (plist-get resolved :raw-response)))
    (lambda (err)
      (chat-ui--render-error ui-buffer err))
    nil
    session)))

(defun chat-ui--render-stream-start-error (ui-buffer)
  "Render a stream startup error in UI-BUFFER."
  (setq chat-ui--active-stream-process nil)
  (message "Error: Failed to start stream process")
  (when (buffer-live-p ui-buffer)
    (with-current-buffer ui-buffer
      (save-excursion
        (goto-char chat-ui--messages-end)
        (insert "[Error: Failed to start stream]\n\n")
        (set-marker chat-ui--messages-end (point))))))

(defun chat-ui--get-response ()
  "Get AI response for current session.
Uses streaming if `chat-ui-use-streaming' is non-nil."
  (if chat-ui-use-streaming
      (chat-ui--get-response-streaming)
    (chat-ui--get-response-sync)))

(defun chat-ui--get-response-sync ()
  "Get AI response through the asynchronous non streaming path."
  (message "Getting response from AI...")
  (chat-log "=== Starting chat-ui--get-response ===")
  (let* ((session chat--current-session)
         (model (chat-session-model-id session))
         (messages (chat-session-messages session))
         (msg-id (format "msg-%s" (random 10000)))
         (buffer (current-buffer))
         assistant-start)
    
    (chat-log "Session: %s, Model: %s, Messages count: %d"
             (chat-session-id session) model (length messages))
    
    ;; Insert assistant header
    (save-excursion
      (goto-char chat-ui--messages-end)
      (insert (propertize "Assistant:\n" 'face 'font-lock-function-name-face))
      (set-marker chat-ui--messages-end (point))
      (setq assistant-start (copy-marker (point))))
    
    ;; Prepare messages with context management and tool calling
    (let* ((messages-with-tools (chat-ui--prepare-messages-with-tools messages))
           (messages-final (chat-context-prepare-messages messages-with-tools)))
      (chat-log "Context: %d messages after filtering" (length messages-final))
      (setq chat-ui--active-request-handle
            (chat-llm-request-async
             model
             messages-final
             (lambda (result)
               (chat-ui--handle-response-success
                session
                msg-id
                buffer
                assistant-start
                model
                messages-final
                result))
             (lambda (err)
               (chat-log "[Async] ERROR: %s" err)
               (chat-ui--render-error buffer err))
             '(:temperature 0.7))))))

;; ------------------------------------------------------------------
;; Interactive Commands
;; ------------------------------------------------------------------

(defun chat-ui--handle-tool-creation (content)
  "Handle tool creation request from CONTENT."
  ;; Show thinking message
  (save-excursion
    (goto-char chat-ui--messages-end)
    (insert (propertize "System:\n" 'face 'font-lock-comment-face))
    (insert "🔨 Creating tool from your request...\n\n")
    (set-marker chat-ui--messages-end (point)))
  ;; Generate tool asynchronously
  (run-with-timer
   0.1 nil
   (lambda ()
     (let ((tool (chat-tool-forge-ai-create-and-register
                  (chat-tool-forge-ai--extract-description content))))
       (if tool
           (progn
             ;; Success message
             (save-excursion
               (goto-char chat-ui--messages-end)
               (insert (propertize "System:\n" 'face 'font-lock-comment-face))
               (insert (format "✅ Tool '%s' (%s) created and registered!\n\n"
                              (chat-forged-tool-name tool)
                              (chat-forged-tool-id tool)))
               (set-marker chat-ui--messages-end (point)))
             ;; Add to session messages
             (chat-session-add-message
              chat--current-session
              (make-chat-message
               :id (format "msg-%s" (random 10000))
               :role :system
               :content (format "Created tool: %s" (chat-forged-tool-name tool))
               :timestamp (current-time))))
         ;; Failure message
         (save-excursion
           (goto-char chat-ui--messages-end)
           (insert (propertize "System:\n" 'face 'font-lock-comment-face))
           (insert "❌ Failed to create tool. Please try again with a clearer description.\n\n")
           (set-marker chat-ui--messages-end (point))))))))

;; ------------------------------------------------------------------
;; Hybrid Mode - Shell & Direct Query
;; ------------------------------------------------------------------

(defun chat-ui--handle-shell-command (command)
  "Execute shell COMMAND and display result in chat buffer.
Handles special case: cd <dir> changes default-directory."
  (let* ((trimmed (string-trim command))
         (is-cd (string-match-p "^cd\\s-+" trimmed)))
    (if (and is-cd (not (string-match-p ";\|&&\|||" trimmed)))
        ;; Handle cd specially
        (let ((dir (substring trimmed (match-end 0))))
          (setq dir (string-trim dir))
          ;; Expand ~ to home
          (when (string-prefix-p "~" dir)
            (setq dir (concat (getenv "HOME") (substring dir 1))))
          ;; Check if directory exists
          (if (file-directory-p dir)
              (progn
                (setq default-directory (file-name-as-directory (expand-file-name dir)))
                (chat-ui--insert-system-message (format "📁 Changed directory to: %s" default-directory)))
            (chat-ui--insert-system-message (format "❌ Directory not found: %s" dir))))
      ;; Normal shell command
      (progn
        (chat-ui--insert-system-message (format "$ %s" trimmed))
        (let ((output (chat-ui--execute-shell-safe trimmed)))
          (if output
              (chat-ui--insert-system-message output)
            (chat-ui--insert-system-message "⚠️ Shell execution disabled or failed")))))))

(defun chat-ui--execute-shell-safe (command)
  "Safely execute shell COMMAND and return output.
Uses chat-tool-shell if available, otherwise basic shell execution."
  (condition-case err
      (if (and (featurep 'chat-tool-shell)
               (fboundp 'chat-tool-shell-execute)
               (boundp 'chat-tool-shell-enabled)
               chat-tool-shell-enabled)
          ;; Use chat-tool-shell if available and enabled
          (chat-tool-shell-execute command)
        ;; Fallback to basic shell execution
        (with-output-to-string
          (with-current-buffer standard-output
            (call-process-shell-command command nil t))))
    (error (format "Error: %s" (error-message-string err)))))

(defun chat-ui--handle-direct-query (question)
  "Ask AI QUESTION directly without saving to session history.
This is an ephemeral query - the result is displayed but not persisted."
  (let ((trimmed (string-trim question)))
    (if (string-empty-p trimmed)
        (message "Empty question. Usage: ?<your question>")
      (chat-ui--insert-user-message (format "?%s" trimmed))
      (chat-ui--insert-system-message "🤖 Asking AI...")
      ;; Get AI response asynchronously
      (let* ((session chat--current-session)
             (model (chat-session-model-id session))
             (msg `((role . "user") (content . ,trimmed)))
             (buffer (current-buffer)))
        (chat-llm-request-async
         model
         (list (make-chat-message
                :id (format "ephemeral-%s" (random 10000))
                :role :user
                :content trimmed
                :timestamp (current-time)))
         (lambda (result)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (let ((content (plist-get result :content)))
                 (chat-ui--insert-ephemeral-response content)))))
         (lambda (err)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (chat-ui--insert-system-message (format "❌ Error: %s" err)))))
         '(:temperature 0.7))))))

(defun chat-ui--insert-system-message (content)
  "Insert a system message CONTENT into chat buffer."
  (save-excursion
    (goto-char chat-ui--messages-end)
    (insert (propertize "System:\n" 'face 'font-lock-comment-face))
    (insert content)
    (insert "\n\n")
    (set-marker chat-ui--messages-end (point))))

(defun chat-ui--insert-user-message (content)
  "Insert a user message CONTENT into chat buffer (ephemeral)."
  (save-excursion
    (goto-char chat-ui--messages-end)
    (insert (propertize "You:\n" 'face 'font-lock-keyword-face))
    (insert (propertize content 'face 'italic))
    (insert "\n\n")
    (set-marker chat-ui--messages-end (point))))

(defun chat-ui--insert-ephemeral-response (content)
  "Insert an ephemeral AI response CONTENT into chat buffer."
  (save-excursion
    (goto-char chat-ui--messages-end)
    ;; Remove the "Asking AI..." message
    (let ((search-start (max (point-min) (- chat-ui--messages-end 500))))
      (goto-char search-start)
      (when (search-forward "🤖 Asking AI..." chat-ui--messages-end t)
        (let ((beg (line-beginning-position)))
          (goto-char chat-ui--messages-end)
          (delete-region beg chat-ui--messages-end)
          (goto-char beg))))
    (insert (propertize "Assistant (quick):\n" 'face 'font-lock-function-name-face))
    (insert content)
    (insert "\n\n")
    (set-marker chat-ui--messages-end (point))))

(defun chat-ui-clear-input ()
  "Clear current input."
  (interactive)
  (when chat-ui--input-overlay
    (delete-region (marker-position chat-ui--input-overlay) (point-max))
    (goto-char (marker-position chat-ui--input-overlay))))

(defun chat-ui-previous-message ()
  "Navigate to previous message."
  (interactive)
  ;; Implementation for history navigation
  (message "History navigation not yet implemented"))

;; ------------------------------------------------------------------
;; View Raw Messages
;; ------------------------------------------------------------------

(defun chat-ui--get-message-at-point ()
  "Get the message struct at point."
  (when (boundp 'chat--current-session)
    (let* ((pos (point))
           (session chat--current-session)
           (messages (chat-session-messages session))
           (current-pos (point-min))
           found-msg)
      (save-excursion
        (goto-char (point-min))
        (while (and (not found-msg) (< (point) (point-max)))
          (when (get-text-property (point) 'chat-message-id)
            (let ((msg-id (get-text-property (point) 'chat-message-id)))
              (setq found-msg (cl-find-if (lambda (m) (equal (chat-message-id m) msg-id))
                                          messages))))
          (forward-line 1)))
      found-msg)))

;;;###autoload
(defun chat-view-raw-message ()
  "View raw API request/response for message at point."
  (interactive)
  (if (and (boundp 'chat--current-session) chat--current-session)
      (let* ((session chat--current-session)
             (messages (chat-session-messages session))
             ;; Find the last assistant message with raw data
             (msg (cl-find-if (lambda (m)
                               (and (eq (chat-message-role m) :assistant)
                                    (or (chat-message-raw-request m)
                                        (chat-message-raw-response m))))
                             (reverse messages))))
        (if msg
            (chat-ui--display-raw-exchange msg)
          (message "No raw message data found in current session")))
    (message "No active chat session")))

(defun chat-ui--display-raw-exchange (msg)
  "Display raw request/response for MSG in a buffer."
  (let* ((msg-id (chat-message-id msg))
         (raw-request (chat-message-raw-request msg))
         (raw-response (chat-message-raw-response msg))
         (buf (get-buffer-create (format "*chat-raw:%s*" msg-id))))
    (with-current-buffer buf
      (erase-buffer)
      (insert "========================================\n")
      (insert (format "Message ID: %s\n" msg-id))
      (insert "========================================\n\n")
      
      (when raw-request
        (insert "--- REQUEST ---\n")
        (insert raw-request)
        (insert "\n\n"))
      
      (when raw-response
        (insert "--- RESPONSE ---\n")
        (insert raw-response)
        (insert "\n")))
    
    (with-current-buffer buf
      (json-pretty-print-buffer)
      (goto-char (point-min))
      (view-mode)
      (pop-to-buffer buf))))

;;;###autoload
(defun chat-view-last-raw-exchange ()
  "View raw API exchange for the last assistant message."
  (interactive)
  (call-interactively 'chat-view-raw-message))

;; ------------------------------------------------------------------
;; Streaming Response (Phase 2)
;; ------------------------------------------------------------------

(defcustom chat-ui-use-streaming nil
  "Use streaming responses for real-time display."
  :type 'boolean
  :group 'chat)

(defvar chat-ui--active-stream-process nil
  "Currently active stream process for cancellation.")

(defun chat-ui--stream-started-p (handle)
  "Return non-nil when HANDLE means stream startup succeeded."
  (not (null handle)))

(defun chat-ui--stream-process-p (process)
  "Return non-nil when PROCESS is a valid stream process."
  (processp process))

(defun chat-ui--set-stream-process-sentinel (process sentinel)
  "Install SENTINEL on PROCESS."
  (set-process-sentinel process sentinel))

(defun chat-ui--stream-request (model messages callback options)
  "Start a streaming request for MODEL with MESSAGES."
  (chat-stream-request model messages callback options))

(defun chat-ui--get-response-streaming ()
  "Get AI response with streaming display."
  (message "Getting response from AI...")
  (chat-log "=== Starting streaming response ===")
  (let* ((session chat--current-session)
         (model (chat-session-model-id session))
         (messages (chat-session-messages session))
         (msg-id (format "msg-%s" (random 10000)))
         (ui-buffer (current-buffer))
         (content-acc "")
         assistant-start)
    (save-excursion
      (goto-char chat-ui--messages-end)
      (insert (propertize "Assistant:\n" 'face 'font-lock-function-name-face))
      (set-marker chat-ui--messages-end (point))
      (setq assistant-start (copy-marker (point))))
    (let* ((messages-with-tools (chat-ui--prepare-messages-with-tools messages))
           (messages-final (chat-context-prepare-messages messages-with-tools))
           (request-json
            (json-encode
             (chat-llm--build-request model messages-final
                                      '(:temperature 0.7 :stream t)))))
      (chat-log "[STREAM] Context: %d messages" (length messages-final))
      (chat-log "[STREAM] Starting request to %s with %d messages"
                model
                (length messages-final))
      (let ((stream-process
             (condition-case err
                 (funcall
                  (symbol-function 'chat-ui--stream-request)
                  model
                  messages-final
                  (lambda (chunk)
                    (when (and chunk (> (length chunk) 0))
                      (chat-log "[STREAM-UI] Got chunk: %d bytes" (length chunk))
                      (when (buffer-live-p ui-buffer)
                        (with-current-buffer ui-buffer
                          (setq content-acc (concat content-acc chunk))
                          (save-excursion
                            (goto-char chat-ui--messages-end)
                            (insert chunk)
                            (set-marker chat-ui--messages-end (point)))
                          (redisplay t)))))
                  '(:temperature 0.7 :stream t))
               (error
                (let ((err-message (error-message-string err)))
                  (chat-log "[STREAM] Exception in stream setup: %s" err-message)
                  (message "Stream error: %s" err-message)
                  (when (buffer-live-p ui-buffer)
                    (with-current-buffer ui-buffer
                      (save-excursion
                        (goto-char chat-ui--messages-end)
                        (insert (format "[Error: %s]\n\n" err-message))
                        (set-marker chat-ui--messages-end (point)))))
                  nil)))))
        (setq chat-ui--active-stream-process stream-process)
        (if (chat-ui--stream-started-p stream-process)
            (progn
              (chat-log "[STREAM] Process created successfully: %S" stream-process)
              (funcall
               (symbol-function 'chat-ui--set-stream-process-sentinel)
               stream-process
               (lambda (proc event)
                 (chat-log "[STREAM] Sentinel event: %s" event)
                 (when (string-match-p "finished\\|closed\\|exited" event)
                   (setq chat-ui--active-stream-process nil)
                   (let ((processed
                          (chat-tool-caller-process-response-data content-acc session)))
                     (chat-ui--resolve-tool-loop-async
                      model
                      messages-final
                      processed
                      request-json
                      nil
                      (lambda (resolved)
                        (setq chat-ui--active-request-handle nil)
                        (chat-ui--finalize-response
                         session
                         msg-id
                         ui-buffer
                         assistant-start
                         (plist-get resolved :processed)
                         (plist-get resolved :raw-request)
                         (plist-get resolved :raw-response))
                        (when (buffer-live-p (process-buffer proc))
                          (kill-buffer (process-buffer proc)))
                        (chat-log "[STREAM] Response complete"))
                      (lambda (err-message)
                        (chat-ui--render-error ui-buffer err-message))
                      nil
                      session)))))
          (chat-log "[STREAM] ERROR: Process creation returned nil")
          (chat-ui--render-stream-start-error ui-buffer))))))))

;;;###autoload
(defun chat-ui-cancel-response ()
  "Cancel the current streaming or non streaming response."
  (interactive)
  (when chat-ui--active-request-handle
    (chat-llm-cancel-request chat-ui--active-request-handle)
    (setq chat-ui--active-request-handle nil))
  (when (and chat-ui--active-stream-process
             (process-live-p chat-ui--active-stream-process))
    (delete-process chat-ui--active-stream-process)
    (setq chat-ui--active-stream-process nil)
    (message "Response cancelled")))

(provide 'chat-ui)
;;; chat-ui.el ends here
