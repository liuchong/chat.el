;;; test-chat-context.el --- Tests for chat-context.el -*- lexical-binding: t -*-
;; Copyright (C) 2026 chat.el contributors
;; Author: chat.el contributors
;; Keywords: tests
;;; Commentary:
;; Unit tests for context preparation.
;;; Code:
(require 'ert)
(require 'test-helper)
(require 'chat-context)
(ert-deftest chat-context-prepare-messages-preserves-system-messages ()
  "Test that truncation keeps system guidance."
  (let* ((messages (list
                    (make-chat-message :id "sys-1" :role :system :content "System guidance")
                    (make-chat-message :id "u-1" :role :user :content (make-string 120 ?a))
                    (make-chat-message :id "a-1" :role :assistant :content (make-string 120 ?b))
                    (make-chat-message :id "u-2" :role :user :content "latest question")))
         (prepared (chat-context-prepare-messages messages 40)))
    (should (eq (chat-message-role (car prepared)) :system))
    (should (string= (chat-message-content (car prepared)) "System guidance"))
    (should (string= (chat-message-content (car (last prepared))) "latest question"))))
(ert-deftest chat-context-prepare-messages-adds-summary-for-omitted-history ()
  "Test that omitted history is replaced by a summary message."
  (let* ((messages (list
                    (make-chat-message :id "sys-1" :role :system :content "System guidance")
                    (make-chat-message :id "u-1" :role :user :content "first task")
                    (make-chat-message :id "a-1" :role :assistant :content "first answer")
                    (make-chat-message :id "u-2" :role :user :content (make-string 180 ?x))
                    (make-chat-message :id "a-2" :role :assistant :content "recent answer")))
         (prepared (chat-context-prepare-messages messages 50))
         (summary (seq-find (lambda (msg)
                              (and (eq (chat-message-role msg) :system)
                                   (string-match-p "Earlier conversation summary" (chat-message-content msg))))
                            prepared)))
    (should summary)
    (should (string-match-p "first task" (chat-message-content summary)))))
(ert-deftest chat-context-summary-includes-tool-results ()
  "Test that tool outputs are mentioned in generated summaries."
  (let* ((message (make-chat-message
                   :id "a-1"
                   :role :assistant
                   :content ""
                   :tool-results '("patch applied" "diff clean")))
         (summary (chat-context--summarize-message message)))
    (should (string-match-p "patch applied" summary))
    (should (string-match-p "assistant" summary))))
(provide 'test-chat-context)
;;; test-chat-context.el ends here
