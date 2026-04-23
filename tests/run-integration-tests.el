#!/usr/bin/env emacs -Q -batch -l
;;; run-integration-tests.el --- Integration test runner for chat.el -*- lexical-binding: t -*-

(require 'ert)

(defvar chat-test-run-root nil)

(setq chat-test-run-root (make-temp-file "chat-integration-tests-" t))

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
      (make-directory chat-session-directory t)
      (make-directory chat-tool-forge-directory t)
      (make-directory chat-edit-backup-directory t)
      (make-directory chat-code-intel-index-directory t)
      (setenv "HOME" chat-test-run-root)
      (add-to-list 'load-path (expand-file-name "unit" test-dir))
      (add-to-list 'load-path (expand-file-name "integration" test-dir))
      (load (expand-file-name "test-paths.el" test-dir) nil t)
      (load (expand-file-name "unit/test-helper.el" test-dir) nil t)
      (load (expand-file-name "../chat.el" test-dir) nil t)
      (dolist (test-file (directory-files
                          (expand-file-name "integration" test-dir)
                          t "^test-.*\\.el$"))
        (message "Loading %s..." (file-name-nondirectory test-file))
        (load test-file nil t))
      (let ((ert-batch-backtrace-right-margin 120))
        (ert-run-tests-batch-and-exit)))
  (when (and chat-test-run-root
             (file-directory-p chat-test-run-root))
    (delete-directory chat-test-run-root t)))

;;; run-integration-tests.el ends here
