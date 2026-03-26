;;; chat-tool-forge.el --- Tool forging for self-evolution -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: tools, forge, self-evolution

;; This file is not part of GNU Emacs.

;;; Commentary:

;; This module enables the AI to create, save, and manage custom tools.
;; Tools can be written in Emacs Lisp or other supported languages.
;; This is the core of chat.el's self-evolution capability.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

;; ------------------------------------------------------------------
;; Customization
;; ------------------------------------------------------------------

(defgroup chat-tool-forge nil
  "Tool forging for chat.el."
  :group 'chat)

(defcustom chat-tool-forge-directory
  (expand-file-name "~/.chat/tools/")
  "Directory where forged tools are stored."
  :type 'directory
  :group 'chat-tool-forge)

(defcustom chat-tool-forge-languages
  '((elisp . (:name "Emacs Lisp"
              :extension ".el"
              :executor chat-tool-forge--exec-elisp))
    (python . (:name "Python"
               :extension ".py"
               :executor chat-tool-forge--exec-python)))
  "Supported languages for tool forging."
  :type 'alist
  :group 'chat-tool-forge)

;; ------------------------------------------------------------------
;; Data Structures
;; ------------------------------------------------------------------

(cl-defstruct chat-forged-tool
  id                    ; Symbol identifier
  name                  ; Display name
  description           ; What this tool does
  language              ; Programming language symbol
  source-code           ; Source code string
  compiled-function     ; Compiled function (for elisp)
  parameters            ; Parameter definitions
  version               ; Tool version
  created-at            ; Creation timestamp
  updated-at            ; Last update timestamp
  usage-count           ; How many times used
  is-active)            ; Whether tool is active

;; ------------------------------------------------------------------
;; Registry
;; ------------------------------------------------------------------

(defvar chat-tool-forge--registry (make-hash-table :test 'eq)
  "Registry of loaded forged tools.")

(defun chat-tool-forge-get (id)
  "Get tool by ID from registry."
  (gethash id chat-tool-forge--registry))

(defun chat-tool-forge-list ()
  "List all registered tools."
  (let (tools)
    (maphash (lambda (_id tool) (push tool tools))
             chat-tool-forge--registry)
    (sort tools (lambda (a b)
                  (string< (chat-forged-tool-name a)
                          (chat-forged-tool-name b))))))

(defun chat-tool-forge-register (tool)
  "Register TOOL in the forge."
  ;; Compile elisp tools immediately
  (when (eq (chat-forged-tool-language tool) 'elisp)
    (chat-tool-forge--compile-elisp tool))
  ;; Store in registry
  (puthash (chat-forged-tool-id tool) tool chat-tool-forge--registry)
  ;; Save to disk
  (when (chat-forged-tool-source-code tool)
    (chat-tool-forge--save tool))
  tool)

(defun chat-tool-forge-unload (id)
  "Unload tool by ID."
  (remhash id chat-tool-forge--registry))

;; ------------------------------------------------------------------
;; Tool Execution
;; ------------------------------------------------------------------

(defun chat-tool-forge-execute (id args)
  "Execute tool ID with ARGS."
  (let ((tool (chat-tool-forge-get id)))
    (unless tool
      (error "Tool not found: %s" id))
    (unless (chat-forged-tool-is-active tool)
      (error "Tool is not active: %s" id))
    ;; Increment usage count
    (cl-incf (chat-forged-tool-usage-count tool))
    ;; Execute based on language
    (let* ((lang (chat-forged-tool-language tool))
           (lang-config (cdr (assoc lang chat-tool-forge-languages)))
           (executor (plist-get lang-config :executor)))
      (if executor
          (funcall executor tool args)
        (error "No executor for language: %s" lang)))))

;; ------------------------------------------------------------------
;; Language Executors
;; ------------------------------------------------------------------

(defun chat-tool-forge--exec-elisp (tool args)
  "Execute Emacs Lisp TOOL with ARGS."
  (let ((func (chat-forged-tool-compiled-function tool)))
    (if func
        (apply func args)
      (error "Tool not compiled: %s" (chat-forged-tool-id tool)))))

(defun chat-tool-forge--exec-python (tool args)
  "Execute Python TOOL with ARGS."
  ;; For now, use shell command
  (let ((temp-file (make-temp-file "chat-tool-" nil ".py")))
    (unwind-protect
        (progn
          (with-temp-file temp-file
            (insert (chat-forged-tool-source-code tool)))
          (shell-command-to-string
           (format "python3 %s %s" temp-file
                   (mapconcat #'shell-quote-argument args " "))))
      (delete-file temp-file))))

;; ------------------------------------------------------------------
;; Compilation
;; ------------------------------------------------------------------

(defun chat-tool-forge--compile-elisp (tool)
  "Compile Emacs Lisp TOOL."
  (let ((source (chat-forged-tool-source-code tool)))
    (when source
      (with-temp-buffer
        (insert source)
        (goto-char (point-min))
        (let ((form (chat-tool-forge--read-single-form (current-buffer))))
          (unless (chat-tool-forge--lambda-form-p form)
            (error "Tool source must be exactly one lambda form"))
          (setf (chat-forged-tool-compiled-function tool)
                (eval form t)))))))

(defun chat-tool-forge--read-single-form (buffer)
  "Read exactly one Lisp form from BUFFER."
  (with-current-buffer buffer
    (goto-char (point-min))
    (let ((form (read (current-buffer))))
      (forward-comment (point-max))
      (unless (eobp)
        (error "Tool source must contain exactly one top level form"))
      form)))

(defun chat-tool-forge--lambda-form-p (form)
  "Return non nil when FORM is a lambda expression."
  (and (consp form)
       (eq (car form) 'lambda)))

;; ------------------------------------------------------------------
;; Persistence
;; ------------------------------------------------------------------

(defun chat-tool-forge--ensure-directory ()
  "Ensure tool directory exists."
  (unless (file-directory-p chat-tool-forge-directory)
    (make-directory chat-tool-forge-directory t)))

(defun chat-tool-forge--save (tool)
  "Save TOOL to disk."
  (chat-tool-forge--ensure-directory)
  (let* ((id (chat-forged-tool-id tool))
         (lang (chat-forged-tool-language tool))
         (ext (or (plist-get (cdr (assoc lang chat-tool-forge-languages)) :extension)
                 ".el"))
         (filename (expand-file-name
                   (format "%s%s" id ext)
                   chat-tool-forge-directory)))
    (with-temp-file filename
      (insert (format ";;; chat-tool: %s\n" id))
      (insert (format ";;; name: %s\n" (chat-forged-tool-name tool)))
      (insert (format ";;; description: %s\n" (chat-forged-tool-description tool)))
      (insert (format ";;; language: %s\n" lang))
      (insert (format ";;; version: %s\n" (or (chat-forged-tool-version tool) "1.0.0")))
      (insert (format ";;; created: %s\n\n" (format-time-string "%Y-%m-%dT%H:%M:%S")))
      (when (chat-forged-tool-source-code tool)
        (insert (chat-forged-tool-source-code tool))))))

(defun chat-tool-forge-load-all ()
  "Load all saved tools from disk."
  (chat-tool-forge--ensure-directory)
  (dolist (file (directory-files chat-tool-forge-directory t "\\.el$"))
    (condition-case err
        (chat-tool-forge--load-from-file file)
      (error (message "Failed to load tool from %s: %s" file err)))))

(defun chat-tool-forge--load-from-file (filepath)
  "Load tool from FILEPATH."
  (with-temp-buffer
    (insert-file-contents filepath)
    ;; Parse header
    (let ((id nil) (name nil) (desc nil) (lang 'elisp) (source nil))
      (goto-char (point-min))
      (while (looking-at ";;; ")
        (let ((line (buffer-substring (point) (line-end-position))))
          (cond
           ((string-match "chat-tool: \\(.*\\)" line)
            (setq id (intern (match-string 1 line))))
           ((string-match "name: \\(.*\\)" line)
            (setq name (match-string 1 line)))
           ((string-match "description: \\(.*\\)" line)
            (setq desc (match-string 1 line)))
           ((string-match "language: \\(.*\\)" line)
            (setq lang (intern (match-string 1 line))))))
        (forward-line 1))
      ;; Rest is source code
      (setq source (string-trim (buffer-substring (point) (point-max))))
      (when (string-empty-p source)
        (setq source nil))
      ;; Create and register tool
      (when (and id name)
        (chat-tool-forge-register
         (make-chat-forged-tool
          :id id
          :name name
          :description desc
          :language lang
          :source-code source
          :version "1.0.0"
          :created-at (current-time)
          :updated-at (current-time)
          :usage-count 0
          :is-active t))))))

;; ------------------------------------------------------------------
;; Tool Generation Interface
;; ------------------------------------------------------------------

(defun chat-tool-forge-create-from-description (description)
  "Create a new tool from DESCRIPTION.
This would be called by the AI to generate a tool."
  ;; Placeholder - actual implementation would call LLM
  (message "Tool creation from description: %s" description)
  nil)

(provide 'chat-tool-forge)
;;; chat-tool-forge.el ends here
