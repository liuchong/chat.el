;;; test-chat-approval.el --- Tests for chat-approval -*- lexical-binding: t -*-
;; Copyright (C) 2026 chat.el contributors
;; Author: chat.el contributors
;; Keywords: tests
;;; Commentary:
;; Unit tests for approval handling.
;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'test-helper)
(require 'chat-approval)
(require 'chat-tool-forge)
(ert-deftest chat-approval-allows-safe-tool-without-prompt ()
  "Test that safe tools do not prompt for approval."
  (let ((chat-approval-required-tools '(files_write))
        prompted)
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (_prompt)
                 (setq prompted t)
                 t)))
      (should
       (chat-approval-request-tool-call
        (make-chat-forged-tool
         :id 'files_read
         :name "Read File"
         :language 'elisp
         :is-active t)
        '(:name "files_read" :arguments (("path" . "/tmp/demo.txt")))))
      (should-not prompted))))
(ert-deftest chat-approval-prompts-for-dangerous-tool ()
  "Test that dangerous tools request explicit approval."
  (let ((chat-approval-required-tools '(files_write))
        (chat-approval-noninteractive-policy 'ask)
        captured-prompt)
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (prompt)
                 (setq captured-prompt prompt)
                 t)))
      (should
       (chat-approval-request-tool-call
        (make-chat-forged-tool
         :id 'files_write
         :name "Write File"
         :language 'elisp
         :is-active t)
        '(:name "files_write"
          :arguments (("path" . "/tmp/demo.txt")
                      ("content" . "hello world")))))
      (should (string-match-p "files_write" captured-prompt))
      (should (string-match-p "/tmp/demo.txt" captured-prompt)))))

(ert-deftest chat-approval-prompts-for-tool-creation ()
  "Test that forged tool creation also requests approval."
  (let ((chat-approval-tool-creation-required t)
        (chat-approval-noninteractive-policy 'ask)
        captured-prompt)
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (prompt)
                 (setq captured-prompt prompt)
                 t)))
      (should (chat-approval-request-tool-creation
               "Create a tool that lists windows"
               '(:id window-tool :language elisp)))
      (should (string-match-p "window-tool" captured-prompt)))))
(provide 'test-chat-approval)
;;; test-chat-approval.el ends here
