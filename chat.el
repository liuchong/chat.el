;;; chat.el --- AI chat executor for Emacs -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: chat, ai, llm, tools
;; Version: 0.1.0

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Chat.el is a pure Emacs AI executor inspired by OpenClaw.
;; It provides conversation management, tool forging, file operations,
;; and integration with various LLM providers.

;; Usage:
;;   M-x chat              Start or resume a chat session
;;   M-x chat-new-session  Create a new chat session
;;   M-x chat-list-sessions List all saved sessions

;;; Code:

(require 'cl-lib)

;; ------------------------------------------------------------------
;; Version
;; ------------------------------------------------------------------

(defconst chat-version "0.1.0"
  "Current version of chat.el.")

(defun chat-version ()
  "Return chat.el version string."
  chat-version)

;; ------------------------------------------------------------------
;; Dependencies Loading
;; ------------------------------------------------------------------

;; Load core modules if not already loaded
(unless (featurep 'chat-session)
  (load "chat-session.el" nil t))
(unless (featurep 'chat-files)
  (load "chat-files.el" nil t))
(unless (featurep 'chat-llm)
  (load "chat-llm.el" nil t))
(unless (featurep 'chat-llm-kimi)
  (load "chat-llm-kimi.el" nil t))

;; Load UI
(unless (featurep 'chat-ui)
  (load "chat-ui.el" nil t))

;; Load local configuration if exists
(let ((local-config (expand-file-name "chat-config.local.el"
                                      (file-name-directory load-file-name))))
  (when (file-exists-p local-config)
    (load local-config nil t)))

;; ------------------------------------------------------------------
;; Customization
;; ------------------------------------------------------------------

(defgroup chat nil
  "AI chat executor for Emacs."
  :group 'applications
  :prefix "chat-")

(defcustom chat-default-model 'gpt-4o
  "Default LLM model to use for new sessions."
  :type 'symbol
  :group 'chat)

(defcustom chat-auto-save t
  "Whether to automatically save sessions after each message."
  :type 'boolean
  :group 'chat)

;; ------------------------------------------------------------------
;; Main Entry Points
;; ------------------------------------------------------------------

;;;###autoload
(defun chat ()
  "Start or resume a chat session.

If there are existing sessions, prompts to select one.
Otherwise, creates a new session."
  (interactive)
  (let ((sessions (chat-session-list)))
    (if sessions
        (chat--select-or-create-session sessions)
      (chat-new-session))))

;;;###autoload
(defun chat-new-session (&optional name model)
  "Create a new chat session.

NAME is an optional session name, prompts if not provided.
MODEL is an optional model identifier, uses chat-default-model if not provided."
  (interactive)
  (let* ((session-name (or name
                           (read-string "Session name: "
                                        (format "Chat %s"
                                                (format-time-string "%Y-%m-%d %H:%M")))))
         (model-id (or model chat-default-model))
         (session (chat-session-create session-name model-id)))
    (chat--open-session session)))

;;;###autoload
(defun chat-list-sessions ()
  "Display a list of all saved sessions."
  (interactive)
  (let ((sessions (chat-session-list)))
    (with-current-buffer (get-buffer-create "*Chat Sessions*")
      (erase-buffer)
      (insert "Chat Sessions\n")
      (insert "============\n\n")
      (if sessions
          (dolist (session sessions)
            (insert (format "• %s\n" (chat-session-name session)))
            (insert (format "  ID: %s\n" (chat-session-id session)))
            (insert (format "  Model: %s\n" (chat-session-model-id session)))
            (insert (format "  Updated: %s\n\n"
                           (format-time-string "%Y-%m-%d %H:%M"
                                              (chat-session-updated-at session))))))
        (insert "No sessions found.\n")
        (insert "Create one with M-x chat-new-session\n"))
      (goto-char (point-min))
      (pop-to-buffer (current-buffer))))

;; ------------------------------------------------------------------
;; Internal Functions
;; ------------------------------------------------------------------

(defun chat--select-or-create-session (sessions)
  "Prompt user to select from SESSIONS or create new."
  (let* ((names (mapcar #'chat-session-name sessions))
         (choice (completing-read "Select session (or type new name): "
                                  names
                                  nil
                                  nil)))
    (if (member choice names)
        (let ((session (cl-find choice sessions
                               :key #'chat-session-name
                               :test #'string=)))
          (chat--open-session session))
      (chat-new-session choice))))

(defun chat--open-session (session)
  "Open SESSION in a chat buffer.

SESSION is a chat-session struct."
  (let* ((buffer-name (format "*chat:%s*" (chat-session-name session)))
         (buffer (get-buffer-create buffer-name)))
    (with-current-buffer buffer
      (chat-mode)
      (setq-local chat--current-session session)
      (chat-ui-setup-buffer session))
    (pop-to-buffer buffer)))

;; ------------------------------------------------------------------
;; Chat Mode
;; ------------------------------------------------------------------

(defvar chat--current-session nil
  "Current session in this chat buffer.")

(defvar chat-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") 'chat-send-message)
    (define-key map (kbd "C-c C-n") 'chat-new-session)
    (define-key map (kbd "C-c C-l") 'chat-list-sessions)
    map)
  "Keymap for chat mode buffers.")

(define-derived-mode chat-mode fundamental-mode "Chat"
  "Major mode for chat sessions."
  :group 'chat
  (setq buffer-read-only nil)
  (erase-buffer))

;; ------------------------------------------------------------------
;; Chat Operations
;; ------------------------------------------------------------------

(defun chat-send-message ()
  "Send message in current chat buffer.

This is a placeholder implementation."
  (interactive)
  (message "Message sending not yet implemented in MVP"))

(defun chat--refresh-buffer ()
  "Refresh current chat buffer with session content."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (when chat--current-session
      (insert (format "Session: %s\n" (chat-session-name chat--current-session)))
      (insert (format "Model: %s\n\n" (chat-session-model-id chat--current-session)))
      (dolist (msg (chat-session-messages chat--current-session))
        (insert (format "%s: %s\n\n"
                       (upcase (symbol-name (chat-message-role msg)))
                       (chat-message-content msg))))
      (insert "\n> "))))

;; ------------------------------------------------------------------
;; Provide
;; ------------------------------------------------------------------

(provide 'chat)
;;; chat.el ends here
