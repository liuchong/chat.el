;;; test-chat.el --- Tests for main chat.el entry point -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: tests

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Unit tests for chat.el main entry point and configuration.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'test-helper)
(require 'chat)

;; ------------------------------------------------------------------
;; Feature Loading
;; ------------------------------------------------------------------

(ert-deftest chat-feature-is-loaded ()
  "Test that chat feature is properly loaded."
  (should (featurep 'chat)))

;; ------------------------------------------------------------------
;; Configuration Variables
;; ------------------------------------------------------------------

(ert-deftest chat-default-model-is-set ()
  "Test that chat-default-model has a default value."
  (should chat-default-model)
  (should (symbolp chat-default-model))
  (should (eq chat-default-model 'kimi)))

(ert-deftest chat-load-config-files-loads-supported-locations-in-order ()
  "Test config files load from all supported locations in override order."
  (chat-test-with-temp-dir
   (let* ((home-dir temp-dir)
          (root-dir (expand-file-name "repo" temp-dir))
          (chat-dir (expand-file-name ".chat" home-dir))
          (process-environment (cons (format "HOME=%s" home-dir)
                                     process-environment))
          loaded-files)
     (make-directory root-dir t)
     (make-directory chat-dir t)
     (with-temp-file (expand-file-name ".chat.el" home-dir)
       (insert "(setq chat-test-config-order '(global-root))\n"
               "(setq chat-test-config-value 'home)\n"))
     (with-temp-file (expand-file-name "config.el" chat-dir)
       (insert "(setq chat-test-config-order (append chat-test-config-order '(chat-dir)))\n"
               "(setq chat-test-config-value 'chat-dir)\n"))
     (with-temp-file (expand-file-name "chat-config.local.el" root-dir)
       (insert "(setq chat-test-config-order (append chat-test-config-order '(project-local)))\n"
               "(setq chat-test-config-value 'project)\n"))
     (setq chat-test-config-order nil)
     (setq chat-test-config-value nil)
     (unwind-protect
         (progn
           (setq loaded-files (chat-load-config-files root-dir))
           (should (equal (mapcar #'file-name-nondirectory loaded-files)
                          '(".chat.el" "config.el" "chat-config.local.el")))
           (should (equal chat-test-config-order
                          '(global-root chat-dir project-local)))
           (should (eq chat-test-config-value 'project)))
       (makunbound 'chat-test-config-order)
       (makunbound 'chat-test-config-value)))))

(ert-deftest chat-session-directory-configurable ()
  "Test that session directory can be configured."
  (chat-test-with-temp-dir
   (let ((chat-session-directory temp-dir))
     (should (string= chat-session-directory temp-dir))
     (chat-session--ensure-directory)
     (should (file-directory-p temp-dir)))))

;; ------------------------------------------------------------------
;; Main Commands
;; ------------------------------------------------------------------

(ert-deftest chat-command-is-bound ()
  "Test that M-x chat is bound."
  (should (fboundp 'chat))
  (should (commandp 'chat)))

(ert-deftest chat-new-session-command-is-bound ()
  "Test that chat-new-session is bound."
  (should (fboundp 'chat-new-session))
  (should (commandp 'chat-new-session)))

(ert-deftest chat-list-sessions-command-is-bound ()
  "Test that chat-list-sessions is bound."
  (should (fboundp 'chat-list-sessions))
  (should (commandp 'chat-list-sessions)))

;; ------------------------------------------------------------------
;; Utility Functions
;; ------------------------------------------------------------------

(ert-deftest chat-version-returns-string ()
  "Test that chat-version returns version string."
  (let ((version (chat-version)))
    (should (stringp version))
    (should (> (length version) 0))))

(ert-deftest chat-registers-core-file-tools ()
  "Test that loading chat registers built in file tools."
  (should (chat-tool-forge-get 'files_read))
  (should (chat-tool-forge-get 'files_patch))
  (should (chat-tool-forge-get 'apply_patch))
  (should (chat-tool-forge-get 'files_write)))

(provide 'test-chat)
;;; test-chat.el ends here
