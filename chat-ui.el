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

(defun chat-ui--get-response ()
  "Get AI response for current session."
  (message "Getting response from AI...")
  (chat-log "=== Starting chat-ui--get-response ===")
  (let* ((session chat--current-session)
         (model (chat-session-model-id session))
         (messages (chat-session-messages session))
         (msg-id (format "msg-%s" (random 10000)))
         (buffer (current-buffer)))
    
    (chat-log "Session: %s, Model: %s, Messages count: %d"
             (chat-session-id session) model (length messages))
    
    ;; Insert assistant header
    (save-excursion
      (goto-char chat-ui--messages-end)
      (insert (propertize "Assistant:\n" 'face 'font-lock-function-name-face))
      (set-marker chat-ui--messages-end (point)))
    
    (chat-log "Starting async request using idle timer")
    
    ;; Use idle timer instead of make-thread (avoids thread variable visibility issues)
    (run-with-idle-timer
     0.1 nil
     (lambda (sess model-id msgs msg-id ui-buffer)
       (chat-log "[Async] Started request")
       (condition-case err
           (let* ((result (chat-llm-request model-id msgs '(:temperature 0.7)))
                  (content (plist-get result :content))
                  (raw-request (plist-get result :raw-request))
                  (raw-response (plist-get result :raw-response)))
             (chat-log "[Async] Got response: %s..." 
                      (substring content 0 (min 50 (length content))))
             ;; Schedule UI update on main thread
             (run-at-time 
              0 nil
              (lambda (resp req-json resp-json)
                (chat-log "[UI] Updating buffer")
                (when (buffer-live-p ui-buffer)
                  (with-current-buffer ui-buffer
                    ;; Insert response
                    (save-excursion
                      (goto-char chat-ui--messages-end)
                      (insert resp)
                      (insert "\n\n")
                      (set-marker chat-ui--messages-end (point)))
                    ;; Save to session with raw data
                    (let ((ai-msg (make-chat-message
                                  :id msg-id
                                  :role :assistant
                                  :content resp
                                  :timestamp (current-time)
                                  :raw-request req-json
                                  :raw-response resp-json)))
                      (chat-session-add-message sess ai-msg))
                    (chat-log "[UI] Response saved to session"))))
              content raw-request raw-response))
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
     session model messages msg-id buffer)))

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

(provide 'chat-ui)
;;; chat-ui.el ends here
