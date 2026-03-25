;;; chat-ui.el --- UI components for chat.el -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

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
    (let* ((input-start (marker-position chat-ui--input-overlay))
           (input-end (point-max))
           (content (buffer-substring-no-properties input-start input-end)))
      ;; Clear input
      (delete-region input-start input-end)
      (goto-char input-start)
      ;; Check for tool creation request
      (if (chat-tool-forge-ai--tool-request-p content)
          (chat-ui--handle-tool-creation content)
        ;; Normal message flow
        (let ((user-msg (make-chat-message
                        :id (format "msg-%s" (random 10000))
                        :role :user
                        :content (string-trim content)
                        :timestamp (current-time))))
          (chat-session-add-message chat--current-session user-msg)
          ;; Insert in buffer
          (save-excursion
            (goto-char chat-ui--messages-end)
            (chat-ui--insert-message user-msg)
            (set-marker chat-ui--messages-end (point)))
          ;; Get AI response
          (chat-ui--get-response))))))

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

(defun chat-ui--finalize-response (session msg-id ui-buffer content-start processed
                                           &optional raw-request raw-response)
  "Render PROCESSED response and persist it for SESSION."
  (let* ((content (or (plist-get processed :content) ""))
         (tool-calls (plist-get processed :tool-calls))
         (tool-results (plist-get processed :tool-results))
         (tool-summary (chat-ui--format-tool-results tool-results)))
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
      :content content
      :timestamp (current-time)
      :tool-calls tool-calls
      :tool-results tool-results
      :raw-request raw-request
      :raw-response raw-response))
    (chat-log "[UI] Response saved to session")))

(defun chat-ui--get-response ()
  "Get AI response for current session.
Uses streaming if `chat-ui-use-streaming' is non-nil."
  (if chat-ui-use-streaming
      (chat-ui--get-response-streaming)
    (chat-ui--get-response-sync)))

(defun chat-ui--get-response-sync ()
  "Get AI response synchronously (non-streaming)."
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
      
      (chat-log "Starting async request using idle timer")
      (chat-log "Context: %d messages after filtering" (length messages-final))
      
      ;; Use idle timer instead of make-thread (avoids thread variable visibility issues)
      (run-with-idle-timer
       0.1 nil
       (lambda (sess model-id msgs msg-id ui-buffer)
         (chat-log "[Async] Started request")
         (condition-case err
             (let* ((result (chat-llm-request model-id msgs '(:temperature 0.7)))
                    (content (plist-get result :content))
                    (raw-request (plist-get result :raw-request))
                    (raw-response (plist-get result :raw-response))
                    (processed (chat-tool-caller-process-response-data content)))
               (chat-log "[Async] Got response: %s..." 
                        (substring content 0 (min 50 (length content))))
               (run-at-time 
                0 nil
                (lambda (response-data req-json resp-json)
                  (chat-log "[UI] Updating buffer")
                  (chat-ui--finalize-response
                   sess msg-id ui-buffer assistant-start response-data req-json resp-json))
                processed raw-request raw-response))
           (error
            (chat-log "[Async] ERROR: %s" (error-message-string err))
            (run-at-time 
             0 nil
             (lambda (e)
               (when (buffer-live-p ui-buffer)
                 (with-current-buffer ui-buffer
                   (save-excursion
                     (goto-char chat-ui--messages-end)
                     (insert (format "[Error: %s]" e))
                     (insert "\n\n")
                     (set-marker chat-ui--messages-end (point))))))
             (error-message-string err)))))
       session model messages-final msg-id buffer))))

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

(defun chat-ui--get-response-streaming ()
  "Get AI response with streaming display."
  (message "Getting response from AI...")
  (chat-log "=== Starting streaming response ===")
  (let* ((session chat--current-session)
         (model (chat-session-model-id session))
         (messages (chat-session-messages session))
         (msg-id (format "msg-%s" (random 10000)))
         (buffer (current-buffer))
         (content-acc "")
         assistant-start)
    (save-excursion
      (goto-char chat-ui--messages-end)
      (insert (propertize "Assistant:\n" 'face 'font-lock-function-name-face))
      (set-marker chat-ui--messages-end (point))
      (setq assistant-start (copy-marker (point))))
    (let* ((messages-with-tools (chat-ui--prepare-messages-with-tools messages))
           (messages-final (chat-context-prepare-messages messages-with-tools))
           (raw-request (json-encode
                         (chat-llm--build-request model messages-final
                                                  '(:temperature 0.7 :stream t)))))
      (chat-log "[STREAM] Context: %d messages" (length messages-final))
      (let ((sess session)
            (model-id model)
            (msgs messages-final)
            (id msg-id)
            (ui-buffer buffer)
            (request-json raw-request))
        (run-with-idle-timer
         0.1 nil
         (lambda ()
           (chat-log "[STREAM] Starting request to %s with %d messages"
                     model-id (length msgs))
           (condition-case err
               (progn
                 (setq chat-ui--active-stream-process
                       (chat-stream-request
                        model-id msgs
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
                        '(:temperature 0.7 :stream t)))
                 (if (processp chat-ui--active-stream-process)
                     (progn
                       (chat-log "[STREAM] Process created successfully: %S"
                                 chat-ui--active-stream-process)
                       (set-process-sentinel
                        chat-ui--active-stream-process
                        (lambda (proc event)
                          (chat-log "[STREAM] Sentinel event: %s" event)
                          (when (string-match-p "finished\\|closed" event)
                            (setq chat-ui--active-stream-process nil)
                            (chat-ui--finalize-response
                             sess
                             id
                             ui-buffer
                             assistant-start
                             (chat-tool-caller-process-response-data content-acc)
                             request-json
                             nil)
                            (when (buffer-live-p (process-buffer proc))
                              (kill-buffer (process-buffer proc)))
                            (chat-log "[STREAM] Response complete")))))
                   (chat-log "[STREAM] ERROR: Process creation returned nil")
                   (message "Error: Failed to start stream process")
                   (when (buffer-live-p ui-buffer)
                     (with-current-buffer ui-buffer
                       (save-excursion
                         (goto-char chat-ui--messages-end)
                         (insert "[Error: Failed to start stream]\n\n")
                         (set-marker chat-ui--messages-end (point)))))))
             (error
              (chat-log "[STREAM] Exception in stream setup: %s"
                        (error-message-string err))
              (message "Stream error: %s" (error-message-string err))
              (when (buffer-live-p ui-buffer)
                (with-current-buffer ui-buffer
                  (save-excursion
                    (goto-char chat-ui--messages-end)
                    (insert (format "[Error: %s]\n\n" (error-message-string err)))
                    (set-marker chat-ui--messages-end (point)))))))))))))

;;;###autoload
(defun chat-ui-cancel-response ()
  "Cancel the current streaming response."
  (interactive)
  (when (and chat-ui--active-stream-process
             (process-live-p chat-ui--active-stream-process))
    (delete-process chat-ui--active-stream-process)
    (setq chat-ui--active-stream-process nil)
    (message "Response cancelled")))

(provide 'chat-ui)
;;; chat-ui.el ends here
