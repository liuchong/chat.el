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
(require 'chat-session)
(require 'chat-approval)
(require 'chat-tool-forge)
(require 'chat-tool-shell)
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
  "Test that dangerous tools use the decision hook."
  (let ((chat-approval-required-tools '(files_write))
        (chat-approval-noninteractive-policy 'ask)
        (chat-approval-always-approve-tools nil)
        (chat-approval-auto-approve-global nil)
        (chat-approval-decision-function
         (lambda (_tool-id _arguments &optional _session)
           'allow-once)))
    (should (eq (chat-approval--decide
                 'files_write
                 '(("path" . "/tmp/demo.txt")
                   ("content" . "hello world")))
                'allow-once))))

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

(ert-deftest chat-approval-allow-session-enables-session-auto-approve ()
  "Test session approval choice persists to the session."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-session-create "Approval Session"))
          (chat-approval-required-tools '(files_write))
          (chat-approval-noninteractive-policy 'ask)
          (chat-approval-decision-function
           (lambda (&rest _args)
             'allow-session)))
     (should
      (chat-approval-request-tool-call
       (make-chat-forged-tool
        :id 'files_write
        :name "Write File"
        :language 'elisp
        :is-active t)
       '(:name "files_write"
         :arguments (("path" . "/tmp/demo.txt")
                     ("content" . "hello world")))
       session))
     (should (chat-session-auto-approve-p session)))))

(ert-deftest chat-approval-allow-tool-adds-global-tool-override ()
  "Test tool approval choice persists to the tool override list."
  (let ((chat-approval-required-tools '(files_write))
        (chat-approval-noninteractive-policy 'ask)
        (chat-approval-always-approve-tools nil)
        (chat-approval-decision-function
         (lambda (&rest _args)
           'allow-tool)))
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
    (should (memq 'files_write chat-approval-always-approve-tools))))

(ert-deftest chat-approval-allow-command-adds-shell-whitelist ()
  "Test shell approval choice can whitelist the current command."
  (let ((chat-approval-required-tools '(shell_execute))
        (chat-approval-noninteractive-policy 'ask)
        (chat-tool-shell-whitelist nil)
        (chat-approval-decision-function
         (lambda (&rest _args)
           'allow-command)))
    (should
     (chat-approval-request-tool-call
      (make-chat-forged-tool
       :id 'shell_execute
       :name "Shell Execute"
       :language 'elisp
       :is-active t)
      '(:name "shell_execute"
        :arguments (("command" . "rg -n StickerManager .")))))
    (should (member "rg -n StickerManager ." chat-tool-shell-whitelist))))
(provide 'test-chat-approval)
;;; test-chat-approval.el ends here
