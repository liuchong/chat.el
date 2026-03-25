;;; chat-code-preview.el --- Preview buffer for code edits -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;; Author: chat.el contributors
;; Keywords: chat, code, preview, diff

;; This file is not part of GNU Emacs.

;;; Commentary:

;; This module provides a preview buffer for reviewing AI-generated code edits.
;; Uses diff-mode for displaying changes.
;;
;; Design principle: Preview is shown in a separate buffer that users
;; can switch to manually. No forced window splits.

;;; Code:

(require 'cl-lib)
(require 'diff-mode)

;; ------------------------------------------------------------------
;; Customization
;; ------------------------------------------------------------------

(defgroup chat-code-preview nil
  "Preview buffer for code edits."
  :group 'chat-code
  :prefix "chat-code-preview-")

(defcustom chat-code-preview-buffer-name "*chat-preview*"
  "Name of the preview buffer."
  :type 'string
  :group 'chat-code-preview)

(defcustom chat-code-preview-side-by-side nil
  "Whether to use side-by-side diff view.
If nil, use unified diff format."
  :type 'boolean
  :group 'chat-code-preview)

;; ------------------------------------------------------------------
;; Data Structures
;; ------------------------------------------------------------------

(cl-defstruct chat-code-preview-data
  "Data for a preview."
  edit-id               ; Edit identifier
  file-path             ; Target file path
  original-content      ; Original file content
  new-content           ; New content
  description           ; Edit description
  diff-content          ; Pre-computed diff
  timestamp)            ; Creation time

;; ------------------------------------------------------------------
;; Buffer Management
;; ------------------------------------------------------------------

(defvar chat-code-preview--current-data nil
  "Current preview data in this buffer.")

(defvar chat-code-preview--accept-callback nil
  "Callback to call when user accepts the edit.")

(defvar chat-code-preview--reject-callback nil
  "Callback to call when user rejects the edit.")

(defun chat-code-preview-get-buffer ()
  "Get or create the preview buffer."
  (or (get-buffer chat-code-preview-buffer-name)
      (let ((buffer (get-buffer-create chat-code-preview-buffer-name)))
        (with-current-buffer buffer
          (chat-code-preview-mode))
        buffer)))

(defun chat-code-preview-show (file-path original new &optional description)
  "Show preview of editing FILE-PATH from ORIGINAL to NEW.
Optional DESCRIPTION explains the change.
Returns the preview buffer."
  (let* ((buffer (chat-code-preview-get-buffer))
         (diff (chat-code-preview--generate-diff
                file-path original new description)))
    (with-current-buffer buffer
      (setq-local chat-code-preview--current-data
                  (make-chat-code-preview-data
                   :edit-id (format "edit-%s" (random 100000))
                   :file-path file-path
                   :original-content original
                   :new-content new
                   :description description
                   :diff-content diff
                   :timestamp (current-time)))
      (let ((inhibit-read-only t))
        (erase-buffer)
        ;; Insert header
        (chat-code-preview--insert-header file-path description)
        ;; Insert diff
        (insert diff)
        ;; Finalize
        (goto-char (point-min))
        (forward-line 3) ;; Skip header lines
        (diff-mode))
      (message "Preview created. Press 'a' to accept, 'r' to reject, 'q' to quit"))
    buffer))

(defun chat-code-preview--insert-header (file-path description)
  "Insert header for preview."
  (insert (propertize
           "════════════════════════════════════════════════════════════════════\n"
           'face '(:weight bold)))
  (insert (propertize
           (format "Preview: %s\n" (abbreviate-file-name file-path))
           'face '(:weight bold :height 1.1)))
  (when description
    (insert (propertize
             (format "Description: %s\n" description)
             'face 'shadow)))
  (insert (propertize
           "Commands: [a]ccept  [r]eject  [q]uit  [n]ext  [p]revious\n"
           'face '(:weight bold)))
  (insert (propertize
           "════════════════════════════════════════════════════════════════════\n\n"
           'face '(:weight bold))))

;; ------------------------------------------------------------------
;; Diff Generation
;; ------------------------------------------------------------------

(defun chat-code-preview--generate-diff (file-path original new &optional description)
  "Generate unified diff for FILE-PATH from ORIGINAL to NEW."
  (with-temp-buffer
    (let* ((orig-file (make-temp-file "chat-code-orig-"))
           (new-file (make-temp-file "chat-code-new-"))
           (diff-file (make-temp-file "chat-code-diff-")))
      (unwind-protect
          (progn
            ;; Write original content
            (with-temp-file orig-file
              (insert original))
            ;; Write new content
            (with-temp-file new-file
              (insert new))
            ;; Generate diff
            (call-process "diff" nil nil nil
                          "-u"
                          "-L" (format "a/%s" file-path)
                          "-L" (format "b/%s" file-path)
                          orig-file
                          new-file)
            ;; Read diff output
            (with-temp-buffer
              (call-process "diff" nil t nil
                            "-u"
                            "-L" (format "a/%s" file-path)
                            "-L" (format "b/%s" file-path)
                            orig-file
                            new-file)
              (buffer-string)))
        ;; Cleanup
        (when (file-exists-p orig-file)
          (delete-file orig-file))
        (when (file-exists-p new-file)
          (delete-file new-file))))))

(defun chat-code-preview--generate-diff-internal (original new)
  "Generate a simple internal diff (fallback when diff command not available)."
  (with-temp-buffer
    (insert "--- a/original\n")
    (insert "+++ b/new\n")
    (insert "@@ -1,1 +1,1 @@\n")
    (let ((orig-lines (split-string original "\n"))
          (new-lines (split-string new "\n")))
      ;; Very simple diff - just show all original as removed, all new as added
      (dolist (line orig-lines)
        (insert "-" line "\n"))
      (dolist (line new-lines)
        (insert "+" line "\n")))
    (buffer-string)))

;; ------------------------------------------------------------------
;; Mode Definition
;; ------------------------------------------------------------------

(defvar chat-code-preview-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Accept/Reject
    (define-key map (kbd "a") 'chat-code-preview-accept)
    (define-key map (kbd "r") 'chat-code-preview-reject)
    (define-key map (kbd "q") 'chat-code-preview-quit)
    ;; Navigation
    (define-key map (kbd "n") 'chat-code-preview-next-change)
    (define-key map (kbd "p") 'chat-code-preview-previous-change)
    ;; Edit
    (define-key map (kbd "e") 'chat-code-preview-edit)
    ;; Standard diff-mode keys
    (set-keymap-parent map diff-mode-map)
    map)
  "Keymap for code preview mode.")

(define-derived-mode chat-code-preview-mode diff-mode "Chat-Preview"
  "Major mode for previewing AI-generated code changes.

Commands:
  a - Accept the changes
  r - Reject the changes
  q - Quit preview (return to previous buffer)
  n - Next change
  p - Previous change
  e - Edit the changes manually

This buffer shows a diff view of proposed changes.
Press 'a' to accept and apply the changes to the file.
Press 'r' to discard the changes.

The preview respects your window layout - you can switch
back to the code buffer with C-x b or continue browsing here."
  :group 'chat-code-preview
  (setq buffer-read-only t)
  (setq truncate-lines nil))

;; ------------------------------------------------------------------
;; Commands
;; ------------------------------------------------------------------

(defun chat-code-preview-accept ()
  "Accept the current previewed changes."
  (interactive)
  (if chat-code-preview--current-data
      (progn
        (when chat-code-preview--accept-callback
          (funcall chat-code-preview--accept-callback
                   chat-code-preview--current-data))
        (message "Changes accepted")
        ;; Close preview buffer
        (chat-code-preview-quit))
    (message "No preview data available")))

(defun chat-code-preview-reject ()
  "Reject the current previewed changes."
  (interactive)
  (if chat-code-preview--current-data
      (progn
        (when chat-code-preview--reject-callback
          (funcall chat-code-preview--reject-callback
                   chat-code-preview--current-data))
        (message "Changes rejected")
        (chat-code-preview-quit))
    (message "No preview data available")))

(defun chat-code-preview-quit ()
  "Quit preview buffer and return to previous buffer."
  (interactive)
  (quit-window))

(defun chat-code-preview-next-change ()
  "Navigate to next change in diff."
  (interactive)
  (forward-line 1)
  (if (re-search-forward "^[\\+\\-]" nil t)
      (beginning-of-line)
    (message "No more changes")))

(defun chat-code-preview-previous-change ()
  "Navigate to previous change in diff."
  (interactive)
  (forward-line -1)
  (if (re-search-backward "^[\\+\\-]" nil t)
      (beginning-of-line)
    (message "No previous changes")))

(defun chat-code-preview-edit ()
  "Edit the new content manually."
  (interactive)
  (if chat-code-preview--current-data
      (let* ((data chat-code-preview--current-data)
             (file-path (chat-code-preview-data-file-path data))
             (new-content (chat-code-preview-data-new-content data))
             (edit-buffer (get-buffer-create "*chat-code-edit*")))
        (with-current-buffer edit-buffer
          (erase-buffer)
          (insert new-content)
          (set-buffer-modified-p nil)
          (goto-char (point-min)))
        (pop-to-buffer edit-buffer)
        (message "Edit content, then C-c C-c to confirm, C-c C-k to cancel"))
    (message "No preview data available")))

;; ------------------------------------------------------------------
;; Callback Setup
;; ------------------------------------------------------------------

(defun chat-code-preview-set-callbacks (accept-fn reject-fn)
  "Set ACCEPT-FN and REJECT-FN callbacks for the current preview.
Callbacks will be called with the preview data when user accepts or rejects."
  (setq-local chat-code-preview--accept-callback accept-fn)
  (setq-local chat-code-preview--reject-callback reject-fn))

;; ------------------------------------------------------------------
;; Integration Helpers
;; ------------------------------------------------------------------

(defun chat-code-preview-for-edit (edit)
  "Show preview for EDIT struct (from chat-edit)."
  (let ((buffer (chat-code-preview-show
                 (chat-code-edit-file edit)
                 (chat-code-edit-original-content edit)
                 (chat-code-edit-new-content edit)
                 (chat-code-edit-description edit))))
    (with-current-buffer buffer
      (setq-local chat-code-preview--accept-callback
                  (lambda (_)
                    (chat-code-edit-apply edit)))
      (setq-local chat-code-preview--reject-callback
                  (lambda (_)
                    (message "Edit rejected"))))
    buffer))

;; ------------------------------------------------------------------
;; Provide
;; ------------------------------------------------------------------

(provide 'chat-code-preview)
;;; chat-code-preview.el ends here
