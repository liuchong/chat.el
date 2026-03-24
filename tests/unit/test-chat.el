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
  (should (symbolp chat-default-model)))

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

(provide 'test-chat)
;;; test-chat.el ends here
