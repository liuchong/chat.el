;;; chat.el --- AI chat executor for Emacs -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: chat, ai, llm, tools
;; Version: 0.1.0
;; License: 1PL (One Public License)
;; License URL: https://license.pub/1pl/

;; This file is not part of GNU Emacs.

;; This project is licensed under the One Public License (1PL).
;; See the LICENSE file in the project root or visit
;; https://license.pub/1pl/ for the full license text.

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
(require 'seq)

;; Prefer newer source files over stale byte-compiled artifacts.
(setq load-prefer-newer t)

;; Add runtime module directories to `load-path`.
(defconst chat-root-directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Repository root directory for the current chat.el checkout.")

(let* ((chat-root chat-root-directory)
       (module-dirs '("lisp/core"
                      "lisp/llm"
                      "lisp/tools"
                      "lisp/ui"
                      "lisp/code"
                      "lisp/wiki")))
  (dolist (dir module-dirs)
    (add-to-list 'load-path (expand-file-name dir chat-root))))

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

;; Load core modules.
(require 'chat-log)
(require 'chat-request-diagnostics)
(require 'chat-session)
(require 'chat-stream)
(require 'chat-context)
(require 'chat-files)
(require 'chat-reading)
(require 'chat-approval)
(require 'chat-wiki)

;; Load LLM providers.
(require 'chat-llm)
(require 'chat-llm-kimi)
(require 'chat-llm-kimi-code)
(require 'chat-llm-openai)
(require 'chat-llm-compatible-providers)
(require 'chat-llm-claude)
(require 'chat-llm-gemini)

;; Load tool modules.
(require 'chat-tool-forge)
(require 'chat-tool-forge-ai)
(require 'chat-tool-caller)
(chat-tool-forge-load-all)
(chat-files-register-built-in-tools)
(require 'chat-tool-shell)

;; Load UI after tooling has been registered.
(require 'chat-request-panel)
(require 'chat-ui)

;; Load code mode (optional)
(when (locate-library "chat-code")
  (require 'chat-context-code)
  (require 'chat-edit)
  (require 'chat-code-preview)
  (require 'chat-code-intel)
  (require 'chat-code-lsp)
  (require 'chat-code-refactor)
  (require 'chat-code-test)
  (require 'chat-code-git)
  (require 'chat-code-perf)
  (require 'chat-code))

;; ------------------------------------------------------------------
;; Customization
;; ------------------------------------------------------------------

(defgroup chat nil
  "AI chat executor for Emacs."
  :group 'applications
  :prefix "chat-")

(defcustom chat-default-model 'kimi
  "Default LLM model to use for new sessions."
  :type 'symbol
  :group 'chat)

(defcustom chat-auto-save t
  "Whether to automatically save sessions after each message."
  :type 'boolean
  :group 'chat)

(defcustom chat-commands-help
  "Chat Commands:
  /cancel               - Cancel current AI request
  /new                  - Create new session
  /list                 - List all sessions
  /save                 - Save current session
  /clear                - Clear conversation
  /model <name>         - Switch model

Quick Shell (Hybrid Mode):
  !<cmd>                - Execute shell command directly
  !cd <dir>             - Change working directory
  ?<question>           - Ask AI directly (not saved to history)

Wiki Commands:
  /wiki-ingest <path>   - Ingest source document
  /wiki-query <question> - Query wiki knowledge
  /wiki-lint            - Run wiki health check
  /wiki-index           - Open wiki index
  /wiki-log             - Open wiki log

Type your message and press RET to send."
  "Help text displayed for chat commands."
  :type 'string
  :group 'chat)

(defun chat--config-file-candidates (&optional root-directory)
  "Return config file candidates for ROOT-DIRECTORY.
Later files override earlier ones."
  (list (expand-file-name "~/.chat.el")
        (expand-file-name "~/.chat/config.el")
        (expand-file-name "chat-config.local.el"
                          (or root-directory chat-root-directory))))

(defun chat-load-config-files (&optional root-directory)
  "Load chat config files for ROOT-DIRECTORY.
Returns the list of files that were loaded."
  (let (loaded-files)
    (dolist (file (chat--config-file-candidates root-directory))
      (when (file-exists-p file)
        (load file nil t)
        (push file loaded-files)))
    (nreverse loaded-files)))

(chat-load-config-files chat-root-directory)

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
  (let* ((buffer-name (chat--buffer-name session))
         (buffer (get-buffer-create buffer-name)))
    (with-current-buffer buffer
      (chat-mode)
      (setq-local chat--current-session session)
      (chat-ui-setup-buffer session))
    (setq chat--last-session-id (chat-session-id session))
    (pop-to-buffer buffer)))

(defun chat--buffer-name (session)
  "Return the chat buffer name for SESSION."
  (format "*chat:%s*" (chat-session-name session)))

;; ------------------------------------------------------------------
;; Chat Mode
;; ------------------------------------------------------------------

(defvar chat--current-session nil
  "Current session in this chat buffer.")

(defvar chat--last-session-id nil
  "Most recently opened chat session id.")

(defvar chat-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") 'chat-ui-send-message)
    (define-key map (kbd "C-c C-n") 'chat-new-session)
    (define-key map (kbd "C-c C-l") 'chat-list-sessions)
    (define-key map (kbd "C-g") 'chat-ui-cancel-response)
    (define-key map (kbd "C-c C-a") 'chat-toggle-auto-approve-session)
    (define-key map (kbd "C-c C-s") 'chat-show-current-request-status)
    (define-key map (kbd "C-c C-p") 'chat-ui-toggle-request-panel)
    map)
  "Keymap for chat mode buffers.")

(defun chat--reading-session-name (&optional file)
  "Return a default session name for reading workflow commands."
  (format "Read: %s"
          (file-name-nondirectory
           (or file default-directory))))

(defun chat--resolve-last-session ()
  "Return the most recently opened chat session when it still exists."
  (when (and chat--last-session-id
             (chat-session-exists-p chat--last-session-id))
    (chat-session-load chat--last-session-id)))

(defun chat--ensure-reading-session (&optional file)
  "Return a chat session suitable for reading workflow commands."
  (or (and (derived-mode-p 'chat-mode)
           chat--current-session)
      (chat--resolve-last-session)
      (chat-session-create (chat--reading-session-name file) chat-default-model)))

(defun chat--quote-capture (capture)
  "Insert CAPTURE into a chat session input area."
  (let ((session (chat--ensure-reading-session (plist-get capture :file)))
        (prompt (chat-reading-format-question capture)))
    (chat--open-session session)
    (with-current-buffer (chat--buffer-name session)
      (delete-region (marker-position chat-ui--input-overlay) (point-max))
      (goto-char (marker-position chat-ui--input-overlay))
      (insert prompt))))

(defun chat--ask-capture (capture question)
  "Send QUESTION about CAPTURE in a chat session."
  (let ((session (chat--ensure-reading-session (plist-get capture :file)))
        (prompt (chat-reading-format-question capture question)))
    (chat--open-session session)
    (with-current-buffer (chat--buffer-name session)
      (delete-region (marker-position chat-ui--input-overlay) (point-max))
      (goto-char (marker-position chat-ui--input-overlay))
      (insert prompt)
      (chat-ui-send-message))))

(defun chat-quote-region ()
  "Quote the active region into a chat session."
  (interactive)
  (chat--quote-capture (chat-reading-capture-region)))

(defun chat-ask-region (question)
  "Ask QUESTION about the active region in a chat session."
  (interactive "sQuestion: ")
  (chat--ask-capture (chat-reading-capture-region) question))

(defun chat-quote-defun ()
  "Quote the defun at point into a chat session."
  (interactive)
  (chat--quote-capture (chat-reading-capture-defun)))

(defun chat-ask-defun (question)
  "Ask QUESTION about the defun at point in a chat session."
  (interactive "sQuestion: ")
  (chat--ask-capture (chat-reading-capture-defun) question))

(defun chat-quote-near-point ()
  "Quote nearby context around point into a chat session."
  (interactive)
  (chat--quote-capture (chat-reading-capture-near-point)))

(defun chat-ask-near-point (question)
  "Ask QUESTION about nearby context around point in a chat session."
  (interactive "sQuestion: ")
  (chat--ask-capture (chat-reading-capture-near-point) question))

(defun chat-quote-current-file ()
  "Quote the current file into a chat session."
  (interactive)
  (chat--quote-capture (chat-reading-capture-current-file)))

(defun chat-ask-current-file (question)
  "Ask QUESTION about the current file in a chat session."
  (interactive "sQuestion: ")
  (chat--ask-capture (chat-reading-capture-current-file) question))

(define-derived-mode chat-mode fundamental-mode "Chat"
  "Major mode for chat sessions."
  :group 'chat
  (setq buffer-read-only nil)
  (erase-buffer))

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
;; Auto-Approval Commands
;; ------------------------------------------------------------------

(defun chat-toggle-auto-approve-global ()
  "Toggle global auto-approval setting."
  (interactive)
  (setq chat-approval-auto-approve-global (not chat-approval-auto-approve-global))
  (message "Global auto-approval: %s"
           (if chat-approval-auto-approve-global "enabled" "disabled")))

(defun chat-toggle-auto-approve-session ()
  "Toggle auto-approval for current session."
  (interactive)
  (if (and (boundp 'chat--current-session) chat--current-session)
      (let* ((session chat--current-session)
             (current (chat-session-auto-approve session))
             (new-value (not current)))
        (chat-session-set-auto-approve session new-value)
        (message "Session '%s' auto-approval: %s"
                 (chat-session-name session)
                 (if new-value "enabled" "disabled")))
    (message "No active session")))

(defun chat-add-to-shell-whitelist (pattern)
  "Add PATTERN to shell command whitelist."
  (interactive "sCommand pattern to whitelist (e.g., 'ls ' or 'git status'): ")
  (require 'chat-tool-shell)
  (chat-tool-shell-whitelist-add pattern))

(defun chat-remove-from-shell-whitelist (pattern)
  "Remove PATTERN from shell command whitelist."
  (interactive)
  (require 'chat-tool-shell)
  (if (and (boundp 'chat-tool-shell-whitelist) chat-tool-shell-whitelist)
      (chat-tool-shell-whitelist-remove
       (completing-read "Remove pattern: " chat-tool-shell-whitelist nil t))
    (message "Shell whitelist is empty")))

(defun chat-show-shell-whitelist ()
  "Display current shell command whitelist."
  (interactive)
  (require 'chat-tool-shell)
  (if (and (boundp 'chat-tool-shell-whitelist) chat-tool-shell-whitelist)
      (message "Shell whitelist: %s"
               (mapconcat #'identity chat-tool-shell-whitelist ", "))
    (message "Shell whitelist is empty")))

;; ------------------------------------------------------------------
;; Provide
;; ------------------------------------------------------------------

(provide 'chat)
;;; chat.el ends here
