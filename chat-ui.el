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
      ;; Add user message
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
        (chat-ui--get-response)))))

(defun chat-ui--get-response ()
  "Get AI response for current session."
  (message "Getting response from AI...")
  (let* ((session chat--current-session)
         (model (chat-session-model-id session))
         (messages (chat-session-messages session))
         ;; Insert thinking indicator
         (thinking-msg (make-chat-message
                       :id (format "msg-%s" (random 10000))
                       :role :assistant
                       :content "[thinking...]"
                       :timestamp (current-time))))
    ;; Insert thinking placeholder
    (save-excursion
      (goto-char chat-ui--messages-end)
      (chat-ui--insert-message thinking-msg)
      (set-marker chat-ui--messages-end (point)))
    ;; Make async API call
    (chat-ui--request-async model messages
     (lambda (content)
       ;; Replace thinking with actual response
       (let ((ai-msg (make-chat-message
                     :id (format "msg-%s" (random 10000))
                     :role :assistant
                     :content content
                     :timestamp (current-time))))
         (chat-session-add-message session ai-msg)
         (save-excursion
           (goto-char chat-ui--messages-end)
           (forward-line -3)  ;; Move back to replace [thinking...]
           (delete-region (point) chat-ui--messages-end)
           (chat-ui--insert-message ai-msg)
           (set-marker chat-ui--messages-end (point)))))
     (lambda (error)
       (let ((err-msg (make-chat-message
                      :id (format "msg-%s" (random 10000))
                      :role :assistant
                      :content (format "[Error: %s]" error)
                      :timestamp (current-time))))
         (save-excursion
           (goto-char chat-ui--messages-end)
           (forward-line -3)
           (delete-region (point) chat-ui--messages-end)
           (chat-ui--insert-message err-msg)
           (set-marker chat-ui--messages-end (point))))))))

(defun chat-ui--request-async (model messages success-callback error-callback)
  "Make async request to MODEL with MESSAGES.
SUCCESS-CALLBACK receives response content.
ERROR-CALLBACK receives error message."
  (condition-case err
      (let ((content (chat-llm-request model messages)))
        (funcall success-callback content))
    (error
     (funcall error-callback (error-message-string err)))))

;; ------------------------------------------------------------------
;; Interactive Commands
;; ------------------------------------------------------------------

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
