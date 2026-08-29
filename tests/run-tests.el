#!/usr/bin/env emacs -Q -batch -l
;;; run-tests.el --- Test runner for chat.el -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: tests

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Run all chat.el tests. Execute with:
;;   emacs -Q -batch -l tests/run-tests.el

;;; Code:

(require 'ert)
(require 'json)
(require 'seq)
(require 'subr-x)

(defvar chat-test-run-root nil)

;; Setup load paths
(setq chat-test-run-root (make-temp-file "chat-tests-" t))

(defun chat-test-run--revision ()
  "Return the exact tested Git revision."
  (string-trim
   (with-temp-buffer
     (unless (zerop (process-file "git" nil t nil "rev-parse" "HEAD"))
       (error "Cannot resolve implementation revision"))
     (buffer-string))))

(defun chat-test-run--tree-clean-p ()
  "Return non-nil when the tested worktree is clean."
  (string-empty-p
   (with-temp-buffer
     (unless (zerop (process-file "git" nil t nil "status" "--porcelain"))
       (error "Cannot inspect implementation worktree"))
     (string-trim (buffer-string)))))

(defun chat-test-run--test-records (names)
  "Return bounded result records for canonical test NAMES."
  (vconcat
   (mapcar
    (lambda (name)
      (let* ((test (ert-get-test (intern name)))
             (result (and test (ert-test-most-recent-result test))))
        `((test . ,name)
          (passed . ,(if (and result (ert-test-passed-p result))
                         t :json-false)))))
    names)))

(defun chat-test-run--successful-p (stats)
  "Return non-nil only when ERT STATS contain an entirely passing run."
  (and (not (ert--stats-aborted-p stats))
       (zerop (ert--stats-failed-expected stats))
       (zerop (ert--stats-failed-unexpected stats))
       (zerop (ert--stats-passed-unexpected stats))
       (zerop (ert--stats-skipped stats))))

(defun chat-test-run--write-record (stats)
  "Write the optional canonical record derived from ERT STATS."
  (let ((output (getenv "CHAT_CANONICAL_OUTPUT")))
    (when output
      (let* ((names (chat-coding-acceptance--canonical-test-names))
             (tests (chat-test-run--test-records names))
             (total (length names))
             (passed
              (seq-count (lambda (record) (eq t (alist-get 'passed record)))
                         tests))
             (skipped (ert--stats-skipped stats))
             (unexpected (+ (ert--stats-passed-unexpected stats)
                            (ert--stats-failed-unexpected stats)))
             (failed (- total passed skipped))
             (record
              `((schemaVersion . 1)
                (implementationRevision . ,(chat-test-run--revision))
                (implementationTreeClean .
                                         ,(if (chat-test-run--tree-clean-p)
                                              t :json-false))
                (measuredAt . ,(format-time-string "%FT%T%z"))
                (summary . ((total . ,total) (passed . ,passed)
                            (failed . ,failed) (skipped . ,skipped)
                            (unexpected . ,unexpected)))
                (tests . ,tests)))
             (json-encoding-pretty-print t))
        (make-directory (file-name-directory (expand-file-name output)) t)
        (with-temp-file output
          (insert (json-encode record) "\n"))))))

(let ((exit-code 1))
  (unwind-protect
      (let ((test-dir (file-name-directory load-file-name)))
        (setq default-directory
              (file-name-as-directory
               (file-truename (expand-file-name ".." test-dir))))
        (setq chat-session-directory (expand-file-name "sessions/" chat-test-run-root))
        (setq chat-tool-forge-directory (expand-file-name "tools/" chat-test-run-root))
        (setq chat-edit-backup-directory (expand-file-name "backups/" chat-test-run-root))
        (setq chat-code-intel-index-directory (expand-file-name "index/" chat-test-run-root))
        (setq chat-log-file (expand-file-name "chat.log" chat-test-run-root))
        (setq chat-wiki-root (expand-file-name "wiki/" chat-test-run-root))
        (make-directory chat-session-directory t)
        (make-directory chat-tool-forge-directory t)
        (make-directory chat-edit-backup-directory t)
        (make-directory chat-code-intel-index-directory t)
        (setenv "HOME" chat-test-run-root)
        (add-to-list 'load-path (expand-file-name "unit" test-dir))
        (load (expand-file-name "test-paths.el" test-dir) nil t)
        (load (expand-file-name "unit/test-helper.el" test-dir) nil t)
        (load (expand-file-name "../chat.el" test-dir) nil t)
        (dolist (test-file (directory-files
                            (expand-file-name "unit" test-dir)
                            t "^test-.*\\.el$"))
          (message "Loading %s..." (file-name-nondirectory test-file))
          (load test-file nil t))
        (let* ((ert-batch-backtrace-right-margin 120)
               (stats (ert-run-tests-batch t)))
          (chat-test-run--write-record stats)
          (setq exit-code (if (chat-test-run--successful-p stats) 0 1))))
    (when (and chat-test-run-root
               (file-directory-p chat-test-run-root))
      (delete-directory chat-test-run-root t)))
  (kill-emacs exit-code))

;;; run-tests.el ends here
