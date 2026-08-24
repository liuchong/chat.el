#!/usr/bin/env emacs -Q -batch -l
;;; run-e2e-tests.el --- Deterministic end-to-end runner -*- lexical-binding: t -*-

(require 'ert)

(defvar chat-test-run-root nil)

(setq chat-test-run-root (make-temp-file "chat-e2e-tests-" t))

(unwind-protect
    (let ((test-dir (file-name-directory load-file-name)))
      (setq default-directory
            (file-name-as-directory
             (file-truename (expand-file-name ".." test-dir))))
      (setq chat-session-directory
            (expand-file-name "sessions/" chat-test-run-root)
            chat-tool-forge-directory
            (expand-file-name "tools/" chat-test-run-root)
            chat-edit-backup-directory
            (expand-file-name "backups/" chat-test-run-root)
            chat-code-intel-index-directory
            (expand-file-name "index/" chat-test-run-root)
            chat-log-file
            (expand-file-name "chat.log" chat-test-run-root))
      (dolist (directory
               (list chat-session-directory chat-tool-forge-directory
                     chat-edit-backup-directory
                     chat-code-intel-index-directory))
        (make-directory directory t))
      (setenv "HOME" chat-test-run-root)
      (add-to-list 'load-path (expand-file-name "unit" test-dir))
      (add-to-list 'load-path (expand-file-name "e2e" test-dir))
      (load (expand-file-name "test-paths.el" test-dir) nil t)
      (load (expand-file-name "unit/test-helper.el" test-dir) nil t)
      (load (expand-file-name "../chat.el" test-dir) nil t)
      (dolist (test-file
               (directory-files
                (expand-file-name "e2e" test-dir)
                t "^test-.*\\.el$"))
        (load test-file nil t))
      (let ((ert-batch-backtrace-right-margin 120))
        (ert-run-tests-batch-and-exit)))
  (when (and chat-test-run-root
             (file-directory-p chat-test-run-root))
    (delete-directory chat-test-run-root t)))

;;; run-e2e-tests.el ends here
