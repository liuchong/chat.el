;;; chat-code.el --- AI code editing mode for chat.el -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;; Author: chat.el contributors
;; Keywords: chat, ai, code, programming

;; This file is not part of GNU Emacs.

;;; Commentary:

;; This module provides AI-powered code editing capabilities for chat.el.
;; It implements a specialized chat mode for programming tasks with:
;;
;; - Project-aware context management
;; - Code-specific tools and prompts
;; - Preview-based editing workflow
;; - Single-window design (respects user's window layout)
;;
;; Design principles:
;; - No forced window splits - all operations in single buffer
;; - User controls window layout via standard Emacs commands
;; - Preview in separate buffer, manually switched
;; - All editing actions are atomic and reversible

;;; Code:

(require 'cl-lib)
(require 'project)
(require 'chat-session)
(require 'chat-llm)
(require 'chat-files)
(require 'chat-context-code)
(require 'chat-edit)
(require 'chat-code-preview)
(require 'chat-code-intel)
(require 'chat-stream)
(require 'chat-code-lsp)

;; ------------------------------------------------------------------
;; Customization
;; ------------------------------------------------------------------

(defgroup chat-code nil
  "AI code editing for chat.el."
  :group 'chat
  :prefix "chat-code-")

(defcustom chat-code-enabled t
  "Enable code mode features."
  :type 'boolean
  :group 'chat-code)

(defcustom chat-code-default-strategy 'balanced
  "Default context strategy for code mode.
\='minimal      - Current file only (~2k tokens)
\='focused      - Current file + related files (~4k tokens)
\='balanced     - + Symbols + Imports (~8k tokens)
\='comprehensive - Full project structure (~16k tokens)"
  :type '(choice (const minimal)
                 (const focused)
                 (const balanced)
                 (const comprehensive))
  :group 'chat-code)

(defcustom chat-code-max-tokens 16000
  "Maximum tokens for code mode context."
  :type 'integer
  :group 'chat-code)

(defcustom chat-code-auto-apply-threshold 10
  "Automatically apply changes smaller than this many lines.
Set to 0 to never auto-apply."
  :type 'integer
  :group 'chat-code)

(defcustom chat-code-system-prompt
  "You are an expert programmer. Help the user write, understand, and modify code.

When making changes:
- Follow existing code style and conventions
- Add error handling where appropriate
- Include tests for new functionality
- Document public APIs with clear docstrings
- Prefer small, focused changes over large rewrites

Available tools:
- files_read: Read file content
- files_write: Write new file
- apply_patch: Apply line-level changes to existing files
- grep_search: Search for patterns in files
- shell_execute: Execute shell commands

Rules:
1. Read files before editing them
2. Use apply_patch for modifying existing files
3. Use files_write mainly for new files
4. After editing, verify the result
5. When generating code, consider the project's existing patterns"
  "System prompt for code mode."
  :type 'string
  :group 'chat-code)

(defcustom chat-code-filetype-map
  '(("\\.py$" . python)
    ("\\.js$" . javascript)
    ("\\.ts$" . typescript)
    ("\\.jsx$" . jsx)
    ("\\.tsx$" . tsx)
    ("\\.el$" . emacs-lisp)
    ("\\.go$" . go)
    ("\\.rs$" . rust)
    ("\\.rb$" . ruby)
    ("\\.java$" . java)
    ("\\.c$" . c)
    ("\\.cpp$" . cpp)
    ("\\.h$" . c)
    ("\\.hpp$" . cpp)
    ("\\.sh$" . shell)
    ("\\.md$" . markdown))
  "File extensions to language mapping."
  :type '(repeat (cons string symbol))
  :group 'chat-code)

;; ------------------------------------------------------------------
;; Data Structures
;; ------------------------------------------------------------------

(cl-defstruct chat-code-session
  "A code editing session.
Inherits from chat-session with additional code-specific fields."
  base-session          ; The underlying chat-session
  project-root          ; Project root directory
  focus-file            ; Currently focused file (if any)
  focus-range           ; Focus range (start . end) in focus-file
  context-strategy      ; Context strategy symbol
  context-files         ; List of files in current context
  language              ; Primary language symbol
  edit-history)         ; List of applied edits

(cl-defstruct chat-code-edit
  "A code edit operation."
  id                    ; Unique identifier
  type                  ; edit type: generate, patch, rewrite, insert, delete
  file                  ; Target file path
  description           ; Human-readable description
  original-content      ; Original content (for undo)
  new-content           ; New content
  range                 ; (start . end) line range
  timestamp             ; Creation time
  applied-p             ; Whether edit has been applied
  backup-file)          ; Path to backup file

;; ------------------------------------------------------------------
;; Session Management
;; ------------------------------------------------------------------

(defvar chat-code--current-session nil
  "Current code mode session in this buffer.")

(defvar chat-code--preview-buffer-name "*chat-preview*"
  "Name of the preview buffer.")

(defun chat-code--detect-language (file-path)
  "Detect programming language for FILE-PATH."
  (let ((ext (file-name-extension file-path)))
    (pcase ext
      ("py" 'python)
      ("js" 'javascript)
      ("ts" 'typescript)
      ("el" 'emacs-lisp)
      ("go" 'go)
      ("rs" 'rust)
      ("rb" 'ruby)
      ("java" 'java)
      (_ nil))))

(defun chat-code--detect-project-root (&optional file)
  "Detect project root for FILE or current buffer."
  (let ((file (or file (buffer-file-name))))
    (or (and file (project-root (project-current nil file)))
        (and file (locate-dominating-file file ".git"))
        (and file (file-name-directory file))
        default-directory)))

(defun chat-code-session-create (name &optional project-root focus-file)
  "Create a new code mode session.

NAME is the session name.
PROJECT-ROOT is the project root directory.
FOCUS-FILE is an optional file to focus on."
  (let* ((project-root (or project-root (chat-code--detect-project-root)))
         (base-session (chat-session-create name chat-default-model))
         (language (and focus-file (chat-code--detect-language focus-file)))
         (code-session (make-chat-code-session
                        :base-session base-session
                        :project-root project-root
                        :focus-file focus-file
                        :context-strategy chat-code-default-strategy
                        :context-files (if focus-file (list focus-file) nil)
                        :language language
                        :edit-history nil)))
    ;; Store code-session in base session metadata
    (setf (chat-session-metadata base-session)
          (plist-put (chat-session-metadata base-session)
                     :code-session code-session))
    code-session))

;; ------------------------------------------------------------------
;; Entry Points
;; ------------------------------------------------------------------

;;;###autoload
(defun chat-code-start (&optional project-root)
  "Start a code mode session for the current project.
Optional PROJECT-ROOT overrides the detected project root."
  (interactive)
  (unless chat-code-enabled
    (error "Code mode is not enabled. Set chat-code-enabled to t"))
  (let* ((project-root (or project-root (chat-code--detect-project-root)))
         (session-name (format "Code: %s"
                               (file-name-nondirectory
                                (directory-file-name project-root))))
         (code-session (chat-code-session-create session-name project-root)))
    (chat-code--open-session code-session)))

;;;###autoload
(defun chat-code-for-file (file-path)
  "Start code mode focused on FILE-PATH."
  (interactive
   (list (read-file-name "Focus file: " nil nil t (buffer-file-name))))
  (unless chat-code-enabled
    (error "Code mode is not enabled. Set chat-code-enabled to t"))
  (let* ((project-root (chat-code--detect-project-root file-path))
         (session-name (format "Code: %s"
                               (file-name-nondirectory file-path)))
         (code-session (chat-code-session-create session-name
                                                  project-root
                                                  file-path)))
    (chat-code--open-session code-session)))

;;;###autoload
(defun chat-code-for-selection ()
  "Start code mode with current selection as context."
  (interactive)
  (unless chat-code-enabled
    (error "Code mode is not enabled. Set chat-code-enabled to t"))
  (let* ((file-path (buffer-file-name))
         (_ (unless file-path
              (error "Buffer is not visiting a file")))
         (project-root (chat-code--detect-project-root file-path))
         (session-name (format "Code: %s"
                               (file-name-nondirectory file-path)))
         (code-session (chat-code-session-create session-name
                                                  project-root
                                                  file-path)))
    ;; Store selection range if active
    (when (region-active-p)
      (setf (chat-code-session-focus-range code-session)
            (cons (line-number-at-pos (region-beginning))
                  (line-number-at-pos (region-end)))))
    (chat-code--open-session code-session)))

;;;###autoload
(defun chat-code-from-chat ()
  "Switch current chat session to code mode."
  (interactive)
  (unless chat-code-enabled
    (error "Code mode is not enabled. Set chat-code-enabled to t"))
  (unless (boundp 'chat--current-session)
    (error "Not in a chat buffer"))
  (let* ((base-session chat--current-session)
         (code-session (chat-code-session-create
                        (chat-session-name base-session)
                        (chat-code--detect-project-root)
                        nil)))
    ;; Reuse existing session but switch to code mode
    (setf (chat-code-session-base-session code-session) base-session)
    (setf (chat-session-metadata base-session)
          (plist-put (chat-session-metadata base-session)
                     :code-session code-session))
    (chat-code--open-session code-session)))

;; ------------------------------------------------------------------
;; Buffer Management
;; ------------------------------------------------------------------

(defun chat-code--buffer-name (session)
  "Generate buffer name for SESSION."
  (format "*chat:code:%s*" (chat-session-name
                            (chat-code-session-base-session session))))

(defun chat-code--open-session (code-session)
  "Open CODE-SESSION in a code mode buffer."
  (let* ((buffer-name (chat-code--buffer-name code-session))
         (buffer (get-buffer-create buffer-name)))
    (with-current-buffer buffer
      (chat-code-mode)
      (setq-local chat-code--current-session code-session)
      (chat-code--setup-buffer code-session))
    (pop-to-buffer buffer)))

(defun chat-code--setup-buffer (code-session)
  "Setup code mode buffer for CODE-SESSION."
  (let ((inhibit-read-only t))
    (erase-buffer)
    ;; Header line with context info
    (chat-code--insert-header code-session)
    ;; Initial context summary
    (chat-code--insert-context-summary code-session)
    ;; Input area
    (chat-code--setup-input-area)))

(defun chat-code--insert-header (code-session)
  "Insert header for CODE-SESSION."
  (insert (propertize
           (format "════════════════════════════════════════════════════════════════════\n"
                   :session "Code Session")
           'face '(:weight bold)))
  (let* ((base (chat-code-session-base-session code-session))
         (name (chat-session-name base))
         (strategy (chat-code-session-context-strategy code-session))
         (project (chat-code-session-project-root code-session))
         (focus (chat-code-session-focus-file code-session)))
    (insert (propertize
             (format "Session: %s | Strategy: %s\n" name strategy)
             'face 'shadow))
    (insert (propertize
             (format "Project: %s\n" (abbreviate-file-name project))
             'face 'shadow))
    (when focus
      (insert (propertize
               (format "Focus: %s\n" (file-name-nondirectory focus))
               'face 'shadow))))
  (insert (propertize
           "════════════════════════════════════════════════════════════════════\n"
           'face '(:weight bold)))
  (insert "\n"))

(defun chat-code--insert-context-summary (code-session)
  "Insert context summary for CODE-SESSION."
  (let ((files (chat-code-session-context-files code-session))
        (focus (chat-code-session-focus-file code-session)))
    (when (or files focus)
      (insert (propertize "[Context] " 'face '(:weight bold)))
      (if files
          (insert (format "%d file(s): %s\n"
                          (length files)
                          (mapconcat #'file-name-nondirectory files ", ")))
        (insert "No files in context\n"))
      (insert "\n"))))

(defun chat-code--setup-input-area ()
  "Setup the input area at bottom of buffer."
  (goto-char (point-max))
  (insert (propertize "────────────────────────────────────────────────────────────────────\n"
                      'face 'shadow))
  (insert "> "))

;; ------------------------------------------------------------------
;; Mode Definition
;; ------------------------------------------------------------------

(defvar chat-code-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Send message
    (define-key map (kbd "RET") 'chat-code-send-message)
    ;; Accept/Reject changes
    (define-key map (kbd "C-c C-a") 'chat-code-accept-last-edit)
    (define-key map (kbd "C-c C-k") 'chat-code-reject-last-edit)
    (define-key map (kbd "C-c C-v") 'chat-code-view-preview)
    ;; Navigation
    (define-key map (kbd "C-c C-f") 'chat-code-focus-file)
    (define-key map (kbd "C-c C-r") 'chat-code-refresh-context)
    ;; Cancel
    (define-key map (kbd "C-g") 'chat-code-cancel)
    map)
  "Keymap for code mode buffers.")

(define-derived-mode chat-code-mode fundamental-mode "Chat-Code"
  "Major mode for AI-assisted code editing.

Key bindings:
  RET        - Send message
  C-c C-a    - Accept last edit
  C-c C-k    - Reject last edit
  C-c C-v    - View preview
  C-c C-f    - Focus on file
  C-c C-r    - Refresh context
  C-g        - Cancel current operation

In this mode, all operations use a single buffer design.
Preview is shown in a separate buffer that you can switch to manually
using C-x b or C-c C-v."
  :group 'chat-code
  (setq buffer-read-only nil)
  (setq truncate-lines nil))

;; ------------------------------------------------------------------
;; Core Commands
;; ------------------------------------------------------------------

(defun chat-code-send-message ()
  "Send message from input area."
  (interactive)
  (when chat-code--current-session
    (let* ((input-start (save-excursion
                          (goto-char (point-max))
                          (beginning-of-line)
                          (forward-char 2) ;; Skip "> "
                          (point)))
           (input-end (point-max))
           (content (string-trim (buffer-substring-no-properties
                                  input-start input-end))))
      (unless (string-empty-p content)
        ;; Clear input
        (delete-region input-start input-end)
        ;; Insert user message
        (save-excursion
          (goto-char (point-max))
          (beginning-of-line)
          (forward-char 2)
          (insert content "\n\n"))
        ;; Process the message
        (chat-code--process-message content)))))

(defun chat-code--process-message (content)
  "Process user message CONTENT."
  (when chat-code--current-session
    (chat-code--send-to-llm content)))

(defcustom chat-code-use-streaming t
  "Whether to use streaming responses for code mode."
  :type 'boolean
  :group 'chat-code)

(defun chat-code--send-to-llm (content)
  "Send CONTENT to LLM and handle response."
  (message "Building context...")
  (let* ((context (chat-context-code-build chat-code--current-session))
         (context-str (chat-context-code-to-string context))
         (lsp-context (when (chat-code-lsp-available-p)
                        (chat-code-lsp-get-context)))
         (lsp-str (when lsp-context
                    (chat-code-lsp-format-context lsp-context)))
         (system-prompt chat-code-system-prompt)
         (full-system-prompt (concat system-prompt "\n\n"
                                     context-str
                                     (when lsp-str
                                       (concat "\n\n" lsp-str))))
         (base-session (chat-code-session-base-session
                        chat-code--current-session))
         (model (chat-session-model-id base-session))
         (messages (list (make-chat-message
                          :id "system-code"
                          :role :system
                          :content full-system-prompt
                          :timestamp (current-time))
                         (make-chat-message
                          :id (format "msg-%s" (random 10000))
                          :role :user
                          :content content
                          :timestamp (current-time)))))
    
    ;; Display user message
    (chat-code--display-user-message content)
    
    ;; Setup input area
    (chat-code--setup-input-area)
    
    ;; Show assistant indicator
    (chat-code--show-assistant-indicator)
    
    ;; Choose streaming or non-streaming
    (if chat-code-use-streaming
        (chat-code--send-streaming model messages)
      (chat-code--send-non-streaming model messages))
    
    ;; Update context
    (setf (chat-code-session-context-files chat-code--current-session)
          (mapcar #'chat-code-file-context-path
                  (chat-code-context-files context)))))

(defun chat-code--send-streaming (model messages)
  "Send streaming request to MODEL with MESSAGES."
  (let* ((buffer (current-buffer))
         (response-start nil)
         (full-content ""))
    ;; Position cursor after "Assistant: Thinking..."
    (save-excursion
      (goto-char (point-max))
      (when (search-backward "Assistant: Thinking..." nil t)
        (delete-region (match-end 0) (point-max))
        (setq response-start (point))
        (insert "\n")))
    
    ;; Start streaming
    (chat-stream-request
     model
     messages
     '(:temperature 0.7)
     ;; Content callback
     (lambda (chunk)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (let ((inhibit-read-only t))
             (goto-char (point-max))
             (insert chunk)
             (setq full-content (concat full-content chunk))))))
     ;; Done callback
     (lambda ()
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (chat-code--finish-response full-content))))
     ;; Error callback
     (lambda (error-msg)
       (when (buffer-live-p buffer)
         (chat-code--handle-llm-error error-msg))))))

(defun chat-code--send-non-streaming (model messages)
  "Send non-streaming request to MODEL with MESSAGES."
  (chat-llm-request-async
   model
   messages
   '(:temperature 0.7)
   (lambda (response)
     (chat-code--handle-llm-response response nil))
   (lambda (error-msg)
     (chat-code--handle-llm-error error-msg))))

(defun chat-code--finish-response (content)
  "Finish processing complete CONTENT from streaming."
  (let ((edit (chat-code--parse-code-edit content)))
    (if edit
        (chat-code--propose-edit edit)
      (progn
        (insert "\n")
        (chat-code--setup-input-area)))))

(defun chat-code--display-user-message (content)
  "Display user message CONTENT in buffer."
  (save-excursion
    (goto-char (point-max))
    (beginning-of-line)
    (forward-char 2) ;; Skip "> "
    (insert (propertize (format "You: %s\n\n" content)
                        'face '(:weight bold)))))

(defun chat-code--show-assistant-indicator ()
  "Show assistant is thinking indicator."
  (save-excursion
    (goto-char (point-max))
    (insert (propertize "Assistant: " 'face '(:weight bold)))
    (insert "Thinking...\n")))

(defun chat-code--handle-llm-response (response original-content)
  "Handle LLM RESPONSE to ORIGINAL-CONTENT."
  (let ((content (plist-get response :content)))
    (when (buffer-live-p (get-buffer (chat-code--buffer-name
                                      chat-code--current-session)))
      (with-current-buffer (chat-code--buffer-name
                            chat-code--current-session)
        (let ((inhibit-read-only t))
          ;; Remove "Thinking..." indicator
          (save-excursion
            (goto-char (point-max))
            (when (search-backward "Assistant: Thinking..." nil t)
              (delete-region (match-beginning 0) (point-max))))
          
          ;; Process response for code edits
          (let ((edit (chat-code--parse-code-edit content)))
            (if edit
                (chat-code--propose-edit edit)
              ;; No code edit, just display response
              (chat-code--display-assistant-response content)))
          
          ;; Setup input area for next message
          (chat-code--setup-input-area))))))

(defun chat-code--handle-llm-error (error-msg)
  "Handle LLM error ERROR-MSG."
  (message "LLM Error: %s" error-msg)
  (when (buffer-live-p (get-buffer (chat-code--buffer-name
                                    chat-code--current-session)))
    (with-current-buffer (chat-code--buffer-name
                          chat-code--current-session)
      (let ((inhibit-read-only t))
        (save-excursion
          (goto-char (point-max))
          (when (search-backward "Assistant: Thinking..." nil t)
            (delete-region (match-beginning 0) (point-max)))
          (insert (propertize "Error: " 'face 'error))
          (insert (format "%s\n\n" error-msg)))
        (chat-code--setup-input-area)))))

(defun chat-code--display-assistant-response (content)
  "Display assistant CONTENT."
  (save-excursion
    (goto-char (point-max))
    (insert (propertize "Assistant: " 'face '(:weight bold)))
    ;; Extract code blocks and display with formatting
    (chat-code--insert-formatted-response content)
    (insert "\n")))

(defun chat-code--insert-formatted-response (content)
  "Insert CONTENT with formatting for code blocks."
  (let ((pos 0)
        (len (length content)))
    (while (< pos len)
      (if (string-match "^\\(```\\([^\n]*\\)\\n\\(.*?\\)\\n```\\)" 
                        (substring content pos) 0)
          ;; Found code block
          (progn
            ;; Insert text before code block
            (insert (substring content pos (+ pos (match-beginning 0))))
            ;; Insert formatted code block
            (let* ((lang (match-string 2 (substring content pos)))
                   (code (match-string 3 (substring content pos)))
                   (face (if (string= lang "")
                             'default
                           '(:background "#f5f5f5" :extend t))))
              (insert (propertize (format "```%s\n%s\n```" lang code)
                                  'face face)))
            (setq pos (+ pos (match-end 0))))
        ;; No more code blocks
        (insert (substring content pos))
        (setq pos len)))))

(defun chat-code--parse-code-edit (content)
  "Parse CODE-EDIT block from CONTENT.
Returns a chat-edit struct or nil."
  ;; Look for code edit markers
  (cond
   ;; Check for explicit CODE-EDIT block
   ((string-match "```code-edit\\n\\(.*?\\)\\n```" content)
    (chat-code--parse-explicit-edit content))
   ;; Check for implied edit (single code block with context)
   ((and (chat-code-session-focus-file chat-code--current-session)
         (string-match "```\\([^\n]*\\)\\n\\(.*?\\)\\n```" content))
    (chat-code--create-edit-from-code-block content))
   (t nil)))

(defun chat-code--parse-explicit-edit (content)
  "Parse explicit CODE-EDIT block."
  ;; TODO: Parse JSON or structured format
  nil)

(defun chat-code--create-edit-from-code-block (content)
  "Create edit from code block in CONTENT."
  (when (string-match "```\\([^\n]*\\)\\n\\(.*?\\)\\n```" content)
    (let* ((file (chat-code-session-focus-file chat-code--current-session))
           (new-code (match-string 2 content))
           (original-code (when file
                            (with-temp-buffer
                              (insert-file-contents file)
                              (buffer-string)))))
      (when (and file original-code)
        (chat-edit-create-rewrite file original-code new-code
                                  "AI suggested change")))))

(defvar chat-code--pending-edit nil
  "Currently pending edit waiting for user confirmation.")

(defun chat-code--propose-edit (edit)
  "Propose EDIT to user."
  (setq chat-code--pending-edit edit)
  
  ;; Display the proposed change
  (save-excursion
    (goto-char (point-max))
    (insert (propertize "Assistant: " 'face '(:weight bold)))
    (insert "I've generated a code change.\n\n")
    (insert (propertize "File: " 'face '(:weight bold)))
    (insert (format "%s\n" (chat-edit-file edit)))
    (insert (propertize "Description: " 'face '(:weight bold)))
    (insert (format "%s\n\n" (chat-edit-description edit)))
    (insert (propertize "[Apply: C-c C-a]  [Preview: C-c C-v]  [Reject: C-c C-k]\n"
                        'face '(:weight bold :foreground "blue")))
    (insert "\n"))
  
  ;; Auto-apply if small enough
  (let ((new-lines (length (split-string (chat-edit-new-content edit) "\n")))
        (orig-lines (length (split-string (chat-edit-original-content edit) "\n"))))
    (when (and (> chat-code-auto-apply-threshold 0)
               (<= (abs (- new-lines orig-lines)) chat-code-auto-apply-threshold))
      (message "Auto-applying small change (%d lines)" 
               (abs (- new-lines orig-lines)))
      (chat-code-accept-last-edit))))

(defun chat-code-accept-last-edit ()
  "Accept the last proposed edit."
  (interactive)
  (if chat-code--pending-edit
      (progn
        (message "Applying edit to %s..." 
                 (file-name-nondirectory (chat-edit-file chat-code--pending-edit)))
        (let ((result (chat-edit-apply chat-code--pending-edit)))
          (if result
              (progn
                (message "Edit applied successfully")
                (chat-edit-add-to-history chat-code--pending-edit)
                ;; Update display
                (save-excursion
                  (goto-char (point-max))
                  (insert (propertize "✓ Edit applied\n\n" 'face '(:foreground "green"))))
                (setq chat-code--pending-edit nil))
            (message "Failed to apply edit"))))
    (message "No pending edit to accept")))

(defun chat-code-reject-last-edit ()
  "Reject the last proposed edit."
  (interactive)
  (if chat-code--pending-edit
      (progn
        (message "Edit rejected")
        (setq chat-code--pending-edit nil)
        ;; Update display
        (save-excursion
          (goto-char (point-max))
          (insert (propertize "✗ Edit rejected\n\n" 'face '(:foreground "red")))))
    (message "No pending edit to reject")))

(defun chat-code-view-preview ()
  "Switch to preview buffer."
  (interactive)
  (let ((preview-buffer (get-buffer chat-code--preview-buffer-name)))
    (if preview-buffer
        (pop-to-buffer preview-buffer)
      (message "No preview available"))))

(defun chat-code-focus-file (file-path)
  "Change focus to FILE-PATH."
  (interactive
   (list (read-file-name "Focus file: "
                         (chat-code-session-project-root
                          chat-code--current-session)
                         nil t)))
  (when chat-code--current-session
    (setf (chat-code-session-focus-file chat-code--current-session) file-path)
    (push file-path (chat-code-session-context-files chat-code--current-session))
    (message "Focus set to: %s" (file-name-nondirectory file-path))))

(defun chat-code-refresh-context ()
  "Refresh context for current session."
  (interactive)
  (when chat-code--current-session
    (message "Refreshing context...")
    ;; TODO: Rebuild context
    ))

(defun chat-code-cancel ()
  "Cancel current operation."
  (interactive)
  (message "Cancel - TODO: implement"))

;; ------------------------------------------------------------------
;; Inline Editing Commands
;; ------------------------------------------------------------------

;;;###autoload
(defun chat-edit-explain ()
  "Explain the code at point or in selection."
  (interactive)
  (let ((code (or (chat-code--get-selection)
                  (chat-code--get-function-at-point)))
        (file (buffer-file-name)))
    (if code
        (chat-code--inline-request
         file
         code
         "Explain this code:\n\n%s\n\nWhat does it do? How does it work?"
         "Code Explanation")
      (message "No code to explain"))))

;;;###autoload
(defun chat-edit-refactor (instruction)
  "Refactor code according to INSTRUCTION."
  (interactive "sRefactor instruction: ")
  (let ((code (or (chat-code--get-selection)
                  (chat-code--get-function-at-point)))
        (file (buffer-file-name)))
    (if code
        (chat-code--inline-request
         file
         code
         (format "Refactor this code: %s\n\n%s\n\nProvide the refactored code."
                 instruction "%s")
         "Code Refactoring")
      (message "No code to refactor"))))

;;;###autoload
(defun chat-edit-fix ()
  "Fix issues in the code at point."
  (interactive)
  (let ((code (or (chat-code--get-selection)
                  (chat-code--get-function-at-point)))
        (file (buffer-file-name)))
    (if code
        (chat-code--inline-request
         file
         code
         "Fix any issues in this code:\n\n%s\n\nProvide the fixed code."
         "Code Fix")
      (message "No code to fix"))))

;;;###autoload
(defun chat-edit-docs ()
  "Generate documentation for the code at point."
  (interactive)
  (let ((code (or (chat-code--get-selection)
                  (chat-code--get-function-at-point)))
        (file (buffer-file-name)))
    (if code
        (chat-code--inline-request
         file
         code
         "Add documentation to this code:\n\n%s\n\nProvide the documented code with docstrings/comments."
         "Add Documentation")
      (message "No code to document"))))

;;;###autoload
(defun chat-edit-tests ()
  "Generate tests for the code at point."
  (interactive)
  (let ((code (or (chat-code--get-selection)
                  (chat-code--get-function-at-point)))
        (file (buffer-file-name)))
    (if code
        (chat-code--inline-request
         file
         code
         "Generate unit tests for this code:\n\n%s\n\nProvide comprehensive tests."
         "Generate Tests")
      (message "No code to test"))))

;;;###autoload
(defun chat-edit-complete ()
  "Complete the current code at point."
  (interactive)
  (let ((code (chat-code--get-context-around-point))
        (file (buffer-file-name)))
    (if code
        (chat-code--inline-request
         file
         code
         "Complete this code:\n\n%s\n\nContinue the implementation."
         "Code Completion")
      (message "No context for completion"))))

(defun chat-code--get-selection ()
  "Get selected text as string."
  (when (region-active-p)
    (buffer-substring-no-properties (region-beginning) (region-end))))

(defun chat-code--get-function-at-point ()
  "Get function at point as string."
  (save-excursion
    (when (beginning-of-defun)
      (let ((start (point)))
        (end-of-defun)
        (buffer-substring-no-properties start (point))))))

(defun chat-code--get-context-around-point ()
  "Get context around point (100 chars before and after)."
  (let ((start (max (point-min) (- (point) 100)))
        (end (min (point-max) (+ (point) 100))))
    (buffer-substring-no-properties start end)))

(defun chat-code--inline-request (file code prompt-template title)
  "Send inline request for CODE in FILE.
PROMPT-TEMPLATE is a format string with %s for code.
TITLE is the operation title."
  ;; Create or reuse code mode session
  (let* ((session (or (and (boundp 'chat-code--current-session)
                           chat-code--current-session)
                      (chat-code-session-create
                       title
                       (chat-code--detect-project-root file)
                       file)))
         (full-prompt (format prompt-template code)))
    
    ;; Open code mode buffer
    (chat-code--open-session session)
    
    ;; Set the prompt and send
    (with-current-buffer (chat-code--buffer-name session)
      (goto-char (point-max))
      (when (search-backward "> " nil t)
        (delete-region (point) (point-max))
        (insert full-prompt))
      (chat-code-send-message))))

;; ------------------------------------------------------------------
;; Provide
;; ------------------------------------------------------------------

(provide 'chat-code)
;;; chat-code.el ends here
