;;; chat-code-git.el --- Git integration for chat.el -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;;; Commentary:

;; This module provides Git integration for chat.el.
;; Uses git diff as context, suggests commit messages, reviews changes.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'chat-model-runtime)

;; Declared rather than required: this module is loaded for its commands
;; and reaches the session only to add context to it, so requiring the
;; surface back would invert the dependency.
(defvar chat--current-session)
(declare-function chat-code-session-p "chat-code" (session))
(declare-function chat-code-session-context-files "chat-code" (session))
(declare-function chat-code-session-set-context-files "chat-code"
                  (session value))

(defun chat-code-git--argv (args)
  "Normalize git ARGS into an argv list."
  (cond
   ((null args) nil)
   ((listp args) args)
   ((stringp args) (split-string-and-unquote args))
   (t (error "Invalid git args: %S" args))))

;; ------------------------------------------------------------------
;; Git Utilities
;; ------------------------------------------------------------------

(defun chat-code-git--run (args &optional directory)
  "Run git with ARGS in DIRECTORY.
Returns output string or nil on error."
  (let ((default-directory (or directory default-directory)))
    (with-temp-buffer
      (if (zerop (apply #'call-process "git" nil t nil (chat-code-git--argv args)))
          (buffer-string)
        nil))))

(defun chat-code-git--root ()
  "Get git root directory."
  (let ((output (chat-code-git--run "rev-parse --show-toplevel")))
    (when output
      (string-trim output))))

(defun chat-code-git--has-changes-p ()
  "Check if there are uncommitted changes."
  (let ((output (chat-code-git--run "status --porcelain")))
    (and output (not (string-blank-p output)))))

;; ------------------------------------------------------------------
;; Diff Context
;; ------------------------------------------------------------------

(defun chat-code-git-get-diff (&optional staged)
  "Get git diff.
If STAGED is non-nil, get staged changes."
  (chat-code-git--run (if staged
                         "diff --cached"
                       "diff")))

(defun chat-code-git-get-diff-for-file (file)
  "Get diff for FILE."
  (chat-code-git--run (format "diff -- %s" file)))

(defun chat-code-git-get-staged-files ()
  "Get list of staged files."
  (let ((output (chat-code-git--run "diff --cached --name-only")))
    (when output
      (split-string (string-trim output) "\n" t))))

(defun chat-code-git-get-modified-files ()
  "Get list of modified files."
  (let ((output (chat-code-git--run "diff --name-only")))
    (when output
      (split-string (string-trim output) "\n" t))))

(defun chat-code-git-get-untracked-files ()
  "Get list of untracked files."
  (let ((output (chat-code-git--run "ls-files --others --exclude-standard")))
    (when output
      (split-string (string-trim output) "\n" t))))

;; ------------------------------------------------------------------
;; Context Integration
;; ------------------------------------------------------------------

(defun chat-code-git-get-context ()
  "Get git context for current buffer.
Returns plist with :diff, :staged-files, :modified-files."
  (when (chat-code-git--root)
    (let ((diff (chat-code-git-get-diff))
          (staged (chat-code-git-get-staged-files))
          (modified (chat-code-git-get-modified-files))
          (untracked (chat-code-git-get-untracked-files)))
      (when (or diff staged modified)
        (list :diff diff
              :staged-files staged
              :modified-files modified
              :untracked-files untracked)))))

(defun chat-code-git-format-context (context &optional max-lines)
  "Format git CONTEXT for LLM prompt.
MAX-LINES limits the diff output."
  (let ((max-lines (or max-lines 100))
        (result ""))
    ;; Add modified files
    (when (plist-get context :modified-files)
      (setq result (concat result ";; Modified files:\n"))
      (dolist (file (cl-subseq (plist-get context :modified-files)
                              0 (min 20 (length (plist-get context :modified-files)))))
        (setq result (concat result (format ";;   - %s\n" file)))))
    ;; Add staged files
    (when (plist-get context :staged-files)
      (setq result (concat result "\n;; Staged files:\n"))
      (dolist (file (plist-get context :staged-files))
        (setq result (concat result (format ";;   - %s\n" file)))))
    ;; Add diff (truncated)
    (when (plist-get context :diff)
      (setq result (concat result "\n;; Changes (diff):\n"))
      (let* ((diff (plist-get context :diff))
             (lines (split-string diff "\n"))
             (truncated (cl-subseq lines 0 (min max-lines (length lines)))))
        (setq result (concat result "```diff\n"))
        (dolist (line truncated)
          (setq result (concat result line "\n")))
        (when (> (length lines) max-lines)
          (setq result (concat result ";; ... (truncated)\n")))
        (setq result (concat result "```\n"))))
    result))

;; ------------------------------------------------------------------
;; Commit Message Suggestions
;; ------------------------------------------------------------------

(defun chat-code-git-suggest-commit-message ()
  "Suggest commit message based on staged changes."
  (interactive)
  (unless (chat-code-git--has-changes-p)
    (error "No changes to commit"))
  (let* ((diff (or (chat-code-git-get-diff t)
                  (chat-code-git-get-diff)))
         (files (or (chat-code-git-get-staged-files)
                   (chat-code-git-get-modified-files)))
         (prompt (format "Suggest a concise commit message for these changes:\n\nFiles: %s\n\nDiff:\n```\n%s\n```\n\nCommit message (follow conventional commits format):"
                        (mapconcat #'identity files ", ")
                        (if (> (length diff) 2000)
                            (concat (substring diff 0 2000) "\n...")
                          diff)))
         (buffer (current-buffer)))
    ;; Send to AI
    (chat-model-request-result
     chat-default-model
     (list (make-chat-message
            :id "system"
            :role :system
            :content "You are a commit message expert. Suggest concise, descriptive commit messages following conventional commits format (type: description)."
            :timestamp (current-time))
           (make-chat-message
            :id "user"
            :role :user
            :content prompt
            :timestamp (current-time)))
     (lambda (response)
       (let ((msg (plist-get response :content)))
         (with-current-buffer buffer
           (message "Suggested commit message: %s" msg))))
     (lambda (err)
       (message "Error: %s" err))
     '(:temperature 0.3))))

(defun chat-code-git-commit (message)
  "Commit with MESSAGE."
  (interactive "sCommit message: ")
  (let ((output (chat-code-git--run (format "commit -m \"%s\"" message))))
    (if output
        (message "Committed: %s" message)
      (message "Commit failed"))))

;; ------------------------------------------------------------------
;; Change Review
;; ------------------------------------------------------------------

(defun chat-code-git-review-changes ()
  "Review staged or unstaged changes with the typed read-only reviewer."
  (interactive)
  (unless (chat-code-git--has-changes-p)
    (error "No changes to review"))
  (require 'chat-code-review)
  (chat-code-review-current-changes))

;; ------------------------------------------------------------------
;; Pre-commit Check
;; ------------------------------------------------------------------

(defun chat-code-git-pre-commit-check ()
  "Run pre-commit checks with AI."
  (interactive)
  (let* ((files (or (chat-code-git-get-staged-files)
                   (chat-code-git-get-modified-files)))
         (context (mapconcat (lambda (file)
                              (when (file-exists-p file)
                                (with-temp-buffer
                                  (insert-file-contents file)
                                  (format "\n=== %s ===\n%s" file (buffer-string)))))
                            files "\n"))
         (prompt (format "Review these files for issues before committing:\n\n```\n%s\n```\n\nCheck for:\n1. Syntax errors\n2. Style issues\n3. Debug code left in\n4. Missing documentation\n5. Security issues"
                        context)))
    (message "Running pre-commit check...")
    (chat-model-request-result
     chat-default-model
     (list (make-chat-message
            :id "system"
            :role :system
            :content "You are a pre-commit checker. Identify issues that should be fixed before committing."
            :timestamp (current-time))
           (make-chat-message
            :id "user"
            :role :user
            :content prompt
            :timestamp (current-time)))
     (lambda (response)
       (let ((msg (plist-get response :content)))
         (if (string-match-p "no issues\\|looks good\\|LGTM" msg)
             (message "Pre-commit check passed!")
           (progn
             (message "Issues found - see *chat-pre-commit* buffer")
             (with-current-buffer (get-buffer-create "*chat-pre-commit*")
               (erase-buffer)
               (insert "Pre-commit Check Results\n")
               (insert (make-string 40 ?=) "\n\n")
               (insert msg))
             (pop-to-buffer "*chat-pre-commit*")))))
     (lambda (err)
       (message "Check failed: %s" err))
     '(:temperature 0.3))))

;; ------------------------------------------------------------------
;; Integration with chat-code
;; ------------------------------------------------------------------

(defun chat-code-git-add-to-context ()
  "Add the files git reports as modified to this session's context.

Does nothing in a session without code capability, which has no context
file list to add to."
  (when (and (bound-and-true-p chat--current-session)
             (fboundp 'chat-code-session-p)
             (chat-code-session-p chat--current-session))
    (let ((git-ctx (chat-code-git-get-context)))
      (when git-ctx
        ;; Called repeatedly across a session, so union rather than
        ;; append: the same modified file would otherwise accumulate.
        (let ((files (chat-code-session-context-files chat--current-session)))
          (dolist (file (plist-get git-ctx :modified-files))
            (unless (member file files)
              (setq files (append files (list file)))))
          (chat-code-session-set-context-files chat--current-session files))))))

;; ------------------------------------------------------------------
;; Commands
;; ------------------------------------------------------------------

;;;###autoload
(defun chat-code-git-diff ()
  "Show git diff."
  (interactive)
  (let ((diff (chat-code-git-get-diff)))
    (if diff
        (with-current-buffer (get-buffer-create "*chat-git-diff*")
          (erase-buffer)
          (insert diff)
          (diff-mode)
          (pop-to-buffer (current-buffer)))
      (message "No changes"))))

;;;###autoload
(defun chat-code-git-commit-suggest ()
  "Suggest and commit with AI-generated message."
  (interactive)
  (chat-code-git-suggest-commit-message))

;;;###autoload
(defun chat-code-git-review ()
  "Review changes with AI."
  (interactive)
  (chat-code-git-review-changes))

;;;###autoload
(defun chat-code-git-pre-commit ()
  "Run pre-commit checks."
  (interactive)
  (chat-code-git-pre-commit-check))

(provide 'chat-code-git)
;;; chat-code-git.el ends here
