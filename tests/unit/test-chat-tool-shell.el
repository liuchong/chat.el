;;; test-chat-tool-shell.el --- Tests for chat-tool-shell -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: tests

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Unit tests for the built in shell tool registration.

;;; Code:

(require 'ert)
(require 'test-helper)
(require 'chat-tool-shell)

(ert-deftest chat-tool-shell-is-registered-active ()
  "Test that the built in shell tool is active after registration."
  (let ((tool (chat-tool-forge-get 'shell_execute)))
    (should tool)
    (should (chat-forged-tool-is-active tool))
    (should (equal (chat-forged-tool-parameters tool)
                   '((:name "command" :type "string" :required t))))))

(provide 'test-chat-tool-shell)
;;; test-chat-tool-shell.el ends here
