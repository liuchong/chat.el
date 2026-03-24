;;; test-chat-ui.el --- Tests for chat-ui.el -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: tests

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Unit tests for chat-ui.el UI components.

;;; Code:

(require 'ert)
(require 'test-helper)
(require 'chat-ui)

(ert-deftest chat-ui-setup-buffer-creates-correct-structure ()
  "Test that chat-ui-setup-buffer creates proper buffer structure."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-session-create "Test Session" 'kimi)))
     (with-temp-buffer
       (setq-local chat--current-session session)
       (chat-ui-setup-buffer session)
       (goto-char (point-min))
       (should (search-forward "Test Session" nil t))
       (goto-char (point-min))
       (should (search-forward "kimi" nil t))
       (goto-char (point-max))
       (should (search-backward ">" nil t))))))

(provide 'test-chat-ui)
;;; test-chat-ui.el ends here
