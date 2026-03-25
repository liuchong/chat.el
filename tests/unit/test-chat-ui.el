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

(ert-deftest chat-ui-finalize-response-persists-tool-data ()
  "Test that finalized responses replace raw content and persist tool data."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-session-create "Test Session" 'kimi))
          (chat-ui--messages-end nil))
     (with-temp-buffer
       (setq-local chat--current-session session)
       (chat-ui-setup-buffer session)
       (goto-char chat-ui--messages-end)
       (insert "Assistant:\n")
       (set-marker chat-ui--messages-end (point))
       (let ((content-start (copy-marker (point))))
         (insert "{\"function_call\":{\"name\":\"demo\",\"arguments\":{\"input\":\"hello\"}}}")
         (set-marker chat-ui--messages-end (point))
         (chat-ui--finalize-response
          session
          "msg-1"
          (current-buffer)
          content-start
          '(:content ""
            :tool-calls ((:name "demo" :arguments (("input" . "hello"))))
            :tool-results ("done"))
          "{\"request\":true}"
          "{\"response\":true}")
         (should-not (search-backward "function_call" nil t))
         (goto-char (point-min))
         (should (search-forward "[Tools used: done]" nil t))
         (let ((saved (car (last (chat-session-messages session)))))
           (should (equal (chat-message-tool-results saved) '("done")))
           (should (equal (chat-message-tool-calls saved)
                          '((:name "demo" :arguments (("input" . "hello"))))))
           (should (string= (chat-message-raw-request saved) "{\"request\":true}"))
           (should (string= (chat-message-raw-response saved) "{\"response\":true}"))))))))

(provide 'test-chat-ui)
;;; test-chat-ui.el ends here
