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
  "Get AI response for current session with streaming display."
  (message "Getting response from AI...")
  (let* ((session chat--current-session)
         (model (chat-session-model-id session))
         (messages (chat-session-messages session))
         ;; Create message structure
         (msg-id (format "msg-%s" (random 10000)))
         (content-start (point-marker)))
    
    ;; Insert initial assistant message header
    (save-excursion
      (goto-char chat-ui--messages-end)
      (insert (propertize "Assistant:\n" 'face 'font-lock-function-name-face))
      (setq content-start (point-marker))
      (insert "\n\n")
      (set-marker chat-ui--messages-end (point)))
    
    ;; Start streaming request
    (let ((accumulated-content ""))
      (chat-stream-request
       model messages
       (lambda (chunk)
         ;; Called for each content chunk
         (setq accumulated-content (concat accumulated-content chunk))
         (save-excursion
           (goto-char content-start)
           (delete-region content-start chat-ui--messages-end)
           (insert accumulated-content)
           (insert "\n\n")
           (set-marker chat-ui--messages-end (point)))
         (redisplay t))
       '(:temperature 0.7))
      
      ;; Save to session when done
      (let ((ai-msg (make-chat-message
                    :id msg-id
                    :role :assistant
                    :content accumulated-content
                    :timestamp (current-time))))
        (chat-session-add-message session ai-msg)))))

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

(provide 'chat-ui)
;;; chat-ui.el ends here
