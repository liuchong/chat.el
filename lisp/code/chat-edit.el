;;; chat-edit.el --- Edit operations for code mode -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;; Author: chat.el contributors
;; Keywords: chat, code, edit

;; This file is not part of GNU Emacs.

;;; Commentary:

;; This module provides edit operations for code mode.
;; Implements atomic, reversible code edits with backup support.

;;; Code:

(require 'cl-lib)

;; ------------------------------------------------------------------
;; Customization
;; ------------------------------------------------------------------

(defgroup chat-edit nil
  "Edit operations for code mode."
  :group 'chat-code
  :prefix "chat-edit-")

(defcustom chat-edit-backup-directory
  (expand-file-name "~/.chat/backups/")
  "Directory for edit backups."
  :type 'directory
  :group 'chat-edit)

(defcustom chat-edit-keep-backups 7
  "Number of days to keep backups."
  :type 'integer
  :group 'chat-edit)

;; ------------------------------------------------------------------
;; Data Structures
;; ------------------------------------------------------------------

(cl-defstruct chat-edit
  "A code edit operation."
  id                    ; Unique identifier
  type                  ; Type: generate, patch, rewrite, insert, delete
  file                  ; Target file path
  description           ; Human-readable description
  original-content      ; Original content for undo
  new-content           ; New content
  range                 ; (start . end) line range, or nil for whole file
  timestamp             ; Creation time
  applied-p             ; Whether edit has been applied
  backup-file           ; Path to backup file
  preview-shown-p)      ; Whether preview was shown

;; ------------------------------------------------------------------
;; Edit Creation
;; ------------------------------------------------------------------

(defun chat-edit-create (type file description original new &optional range)
  "Create a new edit.

TYPE is one of: generate, patch, rewrite, insert, delete
FILE is the target file path
DESCRIPTION describes the change
ORIGINAL is the original content
NEW is the new content
Optional RANGE is (start . end) line range."
  (make-chat-edit
   :id (format "edit-%s-%s"
               (format-time-string "%Y%m%d%H%M%S")
               (random 10000))
   :type type
   :file file
   :description description
   :original-content original
   :new-content new
   :range range
   :timestamp (current-time)
   :applied-p nil
   :backup-file nil
   :preview-shown-p nil))

(defun chat-edit-create-generate (file content description)
  "Create a 'generate edit for creating new FILE with CONTENT."
  (chat-edit-create 'generate file description "" content nil))

(defun chat-edit-create-patch (file original new range description)
  "Create a 'patch edit for partial modification.
RANGE is (start-line . end-line)."
  (chat-edit-create 'patch file description original new range))

(defun chat-edit-create-rewrite (file original new description)
  "Create a 'rewrite edit for replacing entire file."
  (chat-edit-create 'rewrite file description original new nil))

(defun chat-edit-create-insert (file original new position description)
  "Create an 'insert edit for inserting at POSITION.
POSITION is a line number."
  (chat-edit-create 'insert file description original new (cons position position)))

(defun chat-edit-create-delete (file original range description)
  "Create a 'delete edit for deleting RANGE.
RANGE is (start-line . end-line)."
  (chat-edit-create 'delete file description original "" range))

;; ------------------------------------------------------------------
;; Edit Application
;; ------------------------------------------------------------------

(defun chat-edit-apply (edit)
  "Apply EDIT to the file system.
Returns t on success, nil on failure."
  (when (chat-edit-applied-p edit)
    (error "Edit already applied: %s" (chat-edit-id edit)))
  
  (condition-case err
      (progn
        ;; Create backup
        (chat-edit--create-backup edit)
        ;; Apply the edit
        (chat-edit--write-content edit)
        ;; Mark as applied
        (setf (chat-edit-applied-p edit) t)
        ;; Update file buffer if open
        (chat-edit--refresh-file-buffer (chat-edit-file edit))
        t)
    (error
     (message "Failed to apply edit: %s" (error-message-string err))
     nil)))

(defun chat-edit-undo (edit)
  "Undo EDIT by restoring from backup.
Returns t on success, nil on failure."
  (unless (chat-edit-applied-p edit)
    (error "Edit not yet applied: %s" (chat-edit-id edit)))
  
  (let ((backup-file (chat-edit-backup-file edit)))
    (unless (and backup-file (file-exists-p backup-file))
      (error "Backup file not found for edit: %s" (chat-edit-id edit)))
    
    (condition-case err
        (progn
          ;; Restore from backup
          (copy-file backup-file (chat-edit-file edit) t)
          ;; Mark as not applied
          (setf (chat-edit-applied-p edit) nil)
          ;; Update file buffer
          (chat-edit--refresh-file-buffer (chat-edit-file edit))
          t)
      (error
       (message "Failed to undo edit: %s" (error-message-string err))
       nil))))

(defun chat-edit--write-content (edit)
  "Write edit content to file."
  (let* ((file (chat-edit-file edit))
         (new-content (chat-edit-new-content edit))
         (range (chat-edit-range edit))
         (type (chat-edit-type edit)))
    
    (pcase type
      ;; Generate: create new file
      ('generate
       (chat-edit--ensure-directory (file-name-directory file))
       (with-temp-file file
         (insert new-content)))
      
      ;; Rewrite: replace entire file
      ('rewrite
       (with-temp-file file
         (insert new-content)))
      
      ;; Patch: modify specific range
      ('patch
       (let* ((original-content (chat-edit--read-file file))
              (lines (split-string original-content "\n"))
              (start (car range))
              (end (cdr range)))
         ;; Replace lines start to end with new content
         (let ((new-lines (append
                           (cl-subseq lines 0 (1- start))
                           (split-string new-content "\n")
                           (cl-subseq lines end))))
           (with-temp-file file
             (insert (mapconcat #'identity new-lines "\n"))
             (unless (string-suffix-p "\n" new-content)
               (insert "\n"))))))
      
      ;; Insert: insert at position
      ('insert
       (let* ((original-content (chat-edit--read-file file))
              (lines (split-string original-content "\n"))
              (pos (car range)))
         (let ((new-lines (append
                           (cl-subseq lines 0 pos)
                           (split-string new-content "\n")
                           (cl-subseq lines pos))))
           (with-temp-file file
             (insert (mapconcat #'identity new-lines "\n"))
             (unless (string-suffix-p "\n" new-content)
               (insert "\n"))))))
      
      ;; Delete: delete range
      ('delete
       (let* ((original-content (chat-edit--read-file file))
              (lines (split-string original-content "\n"))
              (start (car range))
              (end (cdr range)))
         (let ((new-lines (append
                           (cl-subseq lines 0 (1- start))
                           (cl-subseq lines end))))
           (with-temp-file file
             (insert (mapconcat #'identity new-lines "\n"))))))
      
      (_ (error "Unknown edit type: %s" type)))))

(defun chat-edit--read-file (file)
  "Read content of FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(defun chat-edit--ensure-directory (dir)
  "Ensure DIR exists."
  (unless (file-directory-p dir)
    (make-directory dir t)))

;; ------------------------------------------------------------------
;; Backup Management
;; ------------------------------------------------------------------

(defun chat-edit--create-backup (edit)
  "Create backup for EDIT."
  (chat-edit--ensure-directory chat-edit-backup-directory)
  (let* ((file (chat-edit-file edit))
         (backup-file (expand-file-name
                       (format "%s.%s.bak"
                               (file-name-nondirectory file)
                               (chat-edit-id edit))
                       chat-edit-backup-directory)))
    ;; Copy original file to backup
    (when (file-exists-p file)
      (copy-file file backup-file t))
    (setf (chat-edit-backup-file edit) backup-file)
    ;; Clean old backups
    (chat-edit--cleanup-backups)))

(defun chat-edit--cleanup-backups ()
  "Remove backups older than chat-edit-keep-backups days."
  (when (file-directory-p chat-edit-backup-directory)
    (let ((cutoff-time (time-subtract (current-time)
                                      (days-to-time chat-edit-keep-backups))))
      (dolist (file (directory-files chat-edit-backup-directory t "\\.bak$"))
        (when (time-less-p (nth 5 (file-attributes file)) cutoff-time)
          (delete-file file))))))

(defun chat-edit--refresh-file-buffer (file)
  "Refresh any buffer visiting FILE."
  (let ((buffer (find-buffer-visiting file)))
    (when buffer
      (with-current-buffer buffer
        (revert-buffer t t t)))))

;; ------------------------------------------------------------------
;; Validation
;; ------------------------------------------------------------------

(defun chat-edit-validate (edit)
  "Validate EDIT before applying.
Returns list of errors, or nil if valid."
  (let (errors)
    ;; Check file path
    (let ((file (chat-edit-file edit)))
      (unless (and file (stringp file) (> (length file) 0))
        (push "Invalid file path" errors))
      ;; For non-generate edits, file should exist
      (unless (eq (chat-edit-type edit) 'generate)
        (unless (file-exists-p file)
          (push (format "File does not exist: %s" file) errors))))
    
    ;; Check content
    (unless (stringp (chat-edit-new-content edit))
      (push "New content is not a string" errors))
    
    ;; Check range for patch/insert/delete
    (when (memq (chat-edit-type edit) '(patch insert delete))
      (let ((range (chat-edit-range edit)))
        (unless (and range (consp range)
                     (integerp (car range)) (integerp (cdr range))
                     (> (car range) 0) (>= (cdr range) (car range)))
          (push "Invalid range" errors))))
    
    (nreverse errors)))

;; ------------------------------------------------------------------
;; User Commands
;; ------------------------------------------------------------------

(defvar chat-edit--history nil
  "History of edits in current session.")

;;;###autoload
(defun chat-edit-list-history ()
  "List edit history."
  (interactive)
  (with-current-buffer (get-buffer-create "*chat-edit-history*")
    (erase-buffer)
    (insert "Edit History\n")
    (insert "============\n\n")
    (if chat-edit--history
        (dolist (edit (reverse chat-edit--history))
          (insert (format "[%s] %s: %s (%s) %s\n"
                         (if (chat-edit-applied-p edit) "✓" " ")
                         (chat-edit-id edit)
                         (chat-edit-file edit)
                         (chat-edit-type edit)
                         (or (chat-edit-description edit) ""))))
      (insert "No edits in history.\n"))
    (pop-to-buffer (current-buffer))))

;;;###autoload
(defun chat-edit-undo-last ()
  "Undo the most recent applied edit."
  (interactive)
  (let ((last-edit (cl-find-if #'chat-edit-applied-p
                               chat-edit--history)))
    (if last-edit
        (progn
          (message "Undoing edit: %s" (chat-edit-description last-edit))
          (chat-edit-undo last-edit))
      (message "No applied edit to undo"))))

;; ------------------------------------------------------------------
;; Utility Functions
;; ------------------------------------------------------------------

(defun chat-edit-add-to-history (edit)
  "Add EDIT to history."
  (push edit chat-edit--history))

(defun chat-edit-get-last ()
  "Get the most recent edit."
  (car chat-edit--history))

(defun chat-edit-format-for-display (edit)
  "Format EDIT for display."
  (format "%s %s: %s (%d lines changed)"
          (upcase (symbol-name (chat-edit-type edit)))
          (file-name-nondirectory (chat-edit-file edit))
          (or (chat-edit-description edit) "No description")
          (let ((orig-lines (length (split-string
                                     (chat-edit-original-content edit) "\n")))
                (new-lines (length (split-string
                                    (chat-edit-new-content edit) "\n"))))
            (abs (- new-lines orig-lines)))))

;; ------------------------------------------------------------------
;; Quick Edit Commands
;; ------------------------------------------------------------------

;;;###autoload
(defun chat-edit-apply-patch (file search replace)
  "Apply a simple patch to FILE, replacing SEARCH with REPLACE."
  (interactive
   (list (read-file-name "File: ")
         (read-string "Search: ")
         (read-string "Replace: ")))
  (let* ((content (chat-edit--read-file file))
         (new-content (replace-regexp-in-string
                       (regexp-quote search) replace content t t)))
    (if (string= content new-content)
        (message "No changes made")
      (let ((edit (chat-edit-create-patch
                   file content new-content
                   (cons 1 (length (split-string content "\n")))
                   (format "Replace '%s' with '%s'" search replace))))
        (chat-edit-add-to-history edit)
        (chat-edit-apply edit)
        (message "Patch applied")))))

;; ------------------------------------------------------------------
;; Provide
;; ------------------------------------------------------------------

(provide 'chat-edit)
;;; chat-edit.el ends here
