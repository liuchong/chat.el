;;; test-chat-tool-shell.el --- Tests for chat-tool-shell -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: tests

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Unit tests for the built in shell tool registration.

;;; Code:

(require 'ert)
(require 'subr-x)
(require 'test-helper)
(require 'chat-tool-shell)

(ert-deftest chat-tool-shell-is-registered-active ()
  "Test that the built in shell tool is active after registration."
  (let ((tool (chat-tool-forge-get 'shell_execute)))
    (should tool)
    (should (chat-forged-tool-is-active tool))
    (should (equal (chat-forged-tool-parameters tool)
                   '((:name "command" :type "string" :required t))))))

(ert-deftest chat-tool-shell-allows-directory-size-command ()
  "Test that common directory inspection commands are allowed."
  (should (chat-tool-shell-validate "du -sh ~/Downloads"))
  (should (chat-tool-shell-validate "find . -type d")))

(ert-deftest chat-tool-shell-rejects-shell-metacharacters ()
  "Test that shell metacharacters are rejected."
  (should-not (chat-tool-shell-validate "find . -type d | wc -l"))
  (should-not (chat-tool-shell-validate "echo ok; rm -rf /tmp/demo")))

(ert-deftest chat-tool-shell-executes-without-shell-expansion ()
  "Test shell tool uses argv execution for safe commands."
  (let ((chat-tool-shell-enabled t))
    (should (string= (string-trim (chat-tool-shell-execute "echo hello")) "hello"))))

(provide 'test-chat-tool-shell)
;;; test-chat-tool-shell.el ends here
