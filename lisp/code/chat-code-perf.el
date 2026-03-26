;;; chat-code-perf.el --- Performance optimization for chat.el -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;;; Commentary:

;; This module provides performance optimizations for code mode.
;; Features: incremental indexing, background indexing, cache management.

;;; Code:

(require 'cl-lib)
(require 'chat-code-intel)

;; ------------------------------------------------------------------
;; Incremental Indexing
;; ------------------------------------------------------------------

(defvar chat-code-perf--file-modtimes (make-hash-table :test 'equal)
  "Hash table of file path -> last modified time.")

(defun chat-code-perf-get-changed-files (project-root)
  "Get list of changed files in PROJECT-ROOT since last index."
  (let ((files (chat-code-intel--find-source-files project-root))
        (changed nil))
    (dolist (file files)
      (let ((current-mtime (file-attribute-modification-time
                           (file-attributes file)))
            (last-mtime (gethash file chat-code-perf--file-modtimes)))
        (when (or (null last-mtime)
                  (time-less-p last-mtime current-mtime))
          (push file changed))))
    changed))

(defun chat-code-perf-update-modtimes (files)
  "Update modification times for FILES."
  (dolist (file files)
    (when (file-exists-p file)
      (puthash file
              (file-attribute-modification-time (file-attributes file))
              chat-code-perf--file-modtimes))))

;;;###autoload
(defun chat-code-intel-incremental-update (project-root)
  "Incrementally update index for PROJECT-ROOT.
Only re-indexes changed files."
  (interactive (list (chat-code--detect-project-root)))
  (let ((index (chat-code-intel-get-index project-root)))
    (if (null index)
        (progn
          (setq index (chat-code-intel-index-project project-root))
          (chat-code-perf-update-modtimes (chat-code-index-files index))
          index)
      (let ((changed-files (chat-code-perf-get-changed-files project-root)))
        (if (null changed-files)
            (progn
              (message "No files changed since last index")
              index)
          (message "Incrementally updating %d changed files..."
                   (length changed-files))
          (dolist (file changed-files)
            (chat-code-perf--remove-file-from-index index file))
          (dolist (file changed-files)
            (chat-code-intel--index-file-symbols index file))
          (dolist (file changed-files)
            (chat-code-intel--index-file-references index file))
          (chat-code-intel--build-call-graph index)
          (chat-code-perf-update-modtimes changed-files)
          (chat-code-intel-save-index index)
          (message "Incremental update complete")
          index)))))

(defun chat-code-perf--remove-file-from-index (index file)
  "Remove all entries for FILE from INDEX."
  ;; Remove from files list
  (setf (chat-code-index-files index)
        (delete file (chat-code-index-files index)))
  ;; Remove symbols from this file
  (let ((new-symbols (make-hash-table :test 'equal)))
    (maphash (lambda (name syms)
              (let ((filtered (cl-remove-if
                              (lambda (s)
                                (string= (chat-code-symbol-file s) file))
                              syms)))
                (when filtered
                  (puthash name filtered new-symbols))))
            (chat-code-index-symbols index))
    (setf (chat-code-index-symbols index) new-symbols))
  ;; Remove references from this file
  (let ((new-refs (make-hash-table :test 'equal)))
    (maphash (lambda (name refs)
              (let ((filtered (cl-remove-if
                              (lambda (r)
                                (string= (chat-code-reference-file r) file))
                              refs)))
                (when filtered
                  (puthash name filtered new-refs))))
            (chat-code-index-references index))
    (setf (chat-code-index-references index) new-refs)))

;; ------------------------------------------------------------------
;; Background Indexing
;; ------------------------------------------------------------------

(defvar chat-code-perf--background-process nil
  "Background indexing process.")

(defvar chat-code-perf--background-queue nil
  "Queue of files to index in background.")

(defvar chat-code-perf--background-timer nil
  "Idle timer for background indexing.")

;;;###autoload
(defun chat-code-intel-start-background-index (project-root)
  "Start background indexing for PROJECT-ROOT."
  (interactive (list (chat-code--detect-project-root)))
  ;; Stop existing process
  (chat-code-intel-stop-background-index)
  ;; Initialize queue
  (setq chat-code-perf--background-queue
       (chat-code-intel--find-source-files project-root))
  ;; Use an idle timer instead of a dummy subprocess.
  (setq chat-code-perf--background-process t)
  ;; Process files one by one
  (chat-code-perf--process-next-background-file project-root)
  (message "Background indexing started"))

(defun chat-code-perf--process-next-background-file (project-root)
  "Process next file in background queue."
  (when (and chat-code-perf--background-process
            chat-code-perf--background-queue)
    (let ((file (pop chat-code-perf--background-queue))
          (index (or (chat-code-intel-get-index project-root)
                     (chat-code-intel-index-project project-root))))
      (when (and file index)
        ;; Index file
        (chat-code-intel--index-file-symbols index file)
        ;; Schedule next
        (setq chat-code-perf--background-timer
              (run-with-idle-timer 0.1 nil
                                   #'chat-code-perf--process-next-background-file
                                   project-root)))
      (when (and (null chat-code-perf--background-queue) index)
        (chat-code-intel-save-index index)
        (setq chat-code-perf--background-process nil)
        (setq chat-code-perf--background-timer nil)
        (message "Background indexing complete")))))

;;;###autoload
(defun chat-code-intel-stop-background-index ()
  "Stop background indexing."
  (interactive)
  (when (timerp chat-code-perf--background-timer)
    (cancel-timer chat-code-perf--background-timer)
    (setq chat-code-perf--background-timer nil))
  (when (processp chat-code-perf--background-process)
    (delete-process chat-code-perf--background-process)
    (setq chat-code-perf--background-process nil))
  (setq chat-code-perf--background-process nil)
  (setq chat-code-perf--background-queue nil)
  (message "Background indexing stopped"))

;; ------------------------------------------------------------------
;; Cache Management
;; ------------------------------------------------------------------

(defcustom chat-code-perf-cache-max-size (* 100 1024 1024)
  "Maximum cache size in bytes (default 100MB)."
  :type 'integer)

(defcustom chat-code-perf-cache-max-age (* 7 24 60 60)
  "Maximum cache age in seconds (default 7 days)."
  :type 'integer)

(defun chat-code-perf-cleanup-cache ()
  "Clean up old and large cache files."
  (interactive)
  (let ((cache-dir chat-code-intel-index-directory)
       (total-size 0)
       (cutoff-time (time-subtract (current-time)
                                   (seconds-to-time chat-code-perf-cache-max-age)))
       (files nil))
    ;; Collect all cache files
    (when (file-directory-p cache-dir)
      (dolist (file (directory-files cache-dir t "\\.json$"))
        (let ((attrs (file-attributes file)))
          (push (list :path file
                     :size (file-attribute-size attrs)
                     :mtime (file-attribute-modification-time attrs))
               files))))
    ;; Remove old files
    (dolist (file-info files)
      (when (time-less-p (plist-get file-info :mtime) cutoff-time)
        (delete-file (plist-get file-info :path))
        (message "Removed old cache: %s" (plist-get file-info :path))))
    ;; Check total size
    (setq files (cl-remove-if-not (lambda (f) (file-exists-p (plist-get f :path))) files))
    (setq total-size (cl-reduce #'+ files :key (lambda (f) (plist-get f :size))))
    ;; Remove oldest files if over size limit
    (when (> total-size chat-code-perf-cache-max-size)
      (setq files (sort files (lambda (a b)
                               (time-less-p (plist-get a :mtime)
                                           (plist-get b :mtime)))))
      (while (and files (> total-size chat-code-perf-cache-max-size))
        (let ((file (pop files)))
          (setq total-size (- total-size (plist-get file :size)))
          (delete-file (plist-get file :path))
          (message "Removed cache to free space: %s" (plist-get file :path)))))
    (message "Cache cleanup complete")))

;; ------------------------------------------------------------------
;; File Watchers
;; ------------------------------------------------------------------

(defvar chat-code-perf--file-watchers nil
  "List of active file watchers.")

(defun chat-code-perf-setup-watchers (project-root)
  "Set up file watchers for PROJECT-ROOT."
  (interactive (list (chat-code--detect-project-root)))
  ;; Clean up existing watchers
  (chat-code-perf-cleanup-watchers)
  ;; Set up new watcher if file-notify is available
  (when (fboundp 'file-notify-add-watch)
    (let ((watch (file-notify-add-watch
                 project-root
                 '(change attribute)
                 #'chat-code-perf--file-change-callback)))
      (push watch chat-code-perf--file-watchers)
      (message "File watchers set up for %s" project-root))))

(defun chat-code-perf--file-change-callback (event)
  "Handle file change EVENT."
  (let* ((desc (cadr event))
        (action (caddr event))
        (file (cadddr event)))
    (when (and file (member action '(changed created)))
      ;; Schedule incremental update
      (run-with-idle-timer 2 nil #'chat-code-perf--schedule-update file))))

(defvar chat-code-perf--pending-updates nil
  "Set of files pending update.")

(defun chat-code-perf--schedule-update (file)
  "Schedule update for FILE."
  (add-to-list 'chat-code-perf--pending-updates file)
  (run-with-idle-timer 5 nil #'chat-code-perf--process-pending-updates))

(defun chat-code-perf--process-pending-updates ()
  "Process all pending file updates."
  (when chat-code-perf--pending-updates
    (let ((files chat-code-perf--pending-updates))
      (setq chat-code-perf--pending-updates nil)
      ;; Update index for these files
      (dolist (file files)
        (message "Updating index for %s" file))
      ;; Trigger incremental update
      (chat-code-intel-incremental-update (chat-code--detect-project-root)))))

(defun chat-code-perf-cleanup-watchers ()
  "Clean up file watchers."
  (dolist (watch chat-code-perf--file-watchers)
    (when (fboundp 'file-notify-rm-watch)
      (ignore-errors (file-notify-rm-watch watch))))
  (setq chat-code-perf--file-watchers nil))

;; ------------------------------------------------------------------
;; Context Optimization
;; ------------------------------------------------------------------

(defun chat-code-perf-optimize-context-size (context target-tokens)
  "Optimize CONTEXT to fit within TARGET-TOKENS.
Removes low-priority content if needed."
  (let ((current (chat-context-code-total-tokens context)))
    (while (> current target-tokens)
      ;; Try to truncate a file first
      (let ((largest (chat-code-perf--find-largest-truncatable context)))
        (if largest
            (progn
              (chat-context-code--truncate-file-context largest)
              (setq current (chat-context-code--recalculate-tokens context)))
          ;; Remove lowest priority source
          (chat-context-code--remove-lowest-priority context)
          (setq current (chat-context-code--recalculate-tokens context)))))
    context))

(defun chat-code-perf--find-largest-truncatable (context)
  "Find the largest file in CONTEXT that can be truncated."
  (cl-find-if (lambda (fc)
               (and (> (chat-code-file-context-tokens fc) 100)
                    (null (chat-code-file-context-line-range fc))))
             (chat-code-context-files context)))

;; ------------------------------------------------------------------
;; Commands
;; ------------------------------------------------------------------

;;;###autoload
(defun chat-code-incremental-index ()
  "Incrementally update index for current project."
  (interactive)
  (chat-code-intel-incremental-update (chat-code--detect-project-root)))

;;;###autoload
(defun chat-code-start-background-index ()
  "Start background indexing."
  (interactive)
  (chat-code-intel-start-background-index (chat-code--detect-project-root)))

;;;###autoload
(defun chat-code-cleanup-cache ()
  "Clean up old cache files."
  (interactive)
  (chat-code-perf-cleanup-cache))

(provide 'chat-code-perf)
;;; chat-code-perf.el ends here
