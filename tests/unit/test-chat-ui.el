;;; test-chat-ui.el --- Tests for chat-ui.el -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: tests

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Unit tests for chat-ui.el UI components.

;;; Code:

(require 'ert)
(require 'cl-lib)
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
           (should (string= (chat-message-content saved) "done"))
           (should (equal (chat-message-tool-results saved) '("done")))
           (should (equal (chat-message-tool-calls saved)
                          '((:name "demo" :arguments (("input" . "hello"))))))
           (should (string= (chat-message-raw-request saved) "{\"request\":true}"))
           (should (string= (chat-message-raw-response saved) "{\"response\":true}"))))))))

(ert-deftest chat-ui-resolve-tool-loop-requests-followup-answer ()
  "Test that tool results are fed back into a follow-up model call."
  (let* ((initial-messages
          (list (make-chat-message
                 :id "user-1"
                 :role :user
                 :content "执行一个简单命令然后告诉我结果"
                 :timestamp (current-time))))
         (processed '(:content ""
                     :tool-calls ((:name "shell_execute"
                                   :arguments (("command" . "echo tool-ok"))))
                     :tool-results ("tool-ok\n")))
         captured-messages)
    (cl-letf (((symbol-function 'chat-llm-request)
               (lambda (_model messages _options)
                 (setq captured-messages messages)
                 '(:content "命令结果是 tool-ok"
                   :raw-request "{\"step\":2}"
                   :raw-response "{\"answer\":true}"))))
      (let* ((resolved (chat-ui--resolve-tool-loop
                        'kimi-code initial-messages processed "{\"step\":1}" nil))
             (final (plist-get resolved :processed))
             (followup (car (last captured-messages))))
        (should (string= (plist-get final :content) "命令结果是 tool-ok"))
        (should (equal (plist-get final :tool-results) '("tool-ok\n")))
        (should (eq (chat-message-role followup) :system))
        (should (string-match-p "Tool results from the previous step"
                                (chat-message-content followup)))
        (should (string-match-p "tool-ok"
                                (chat-message-content followup)))))))

(provide 'test-chat-ui)
;;; test-chat-ui.el ends here
