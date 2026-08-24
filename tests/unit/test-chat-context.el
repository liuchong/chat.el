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

(ert-deftest chat-context-summary-includes-tool-call-names ()
  "Test that tool call names appear in message summaries."
  (let* ((message (make-chat-message
                   :id "a-2"
                   :role :assistant
                   :content "done"
                   :tool-calls '((:name "files_read" :arguments (("path" . "a.txt"))))
                   :tool-results '("ok")))
         (summary (chat-context--summarize-message message)))
    (should (string-match-p "files_read" summary))
    (should (string-match-p "ok" summary))))

(ert-deftest chat-context-message-tokens-counts-tool-metadata ()
  "Test token estimation accounts for tool metadata."
  (let* ((message (make-chat-message
                   :id "a-3"
                   :role :assistant
                   :content ""
                   :tool-calls '((:name "apply_patch" :arguments (("path" . "demo.el"))))
                   :tool-results '("patched demo.el"))))
    (should (> (chat-context-message-tokens message) 4))))

(ert-deftest chat-context-auto-compaction-persists-and-reuses-summary ()
  "Test over-budget preparation stores and applies a durable summary."
  (let* ((chat-session-auto-save nil)
         (session (make-chat-session :id "compact" :model-id 'kimi))
         (messages
          (cl-loop for index from 1 to 8
                   collect
                   (make-chat-message
                    :id (format "m%d" index)
                    :role (if (cl-oddp index) :user :assistant)
                    :content (format "message-%d %s"
                                     index (make-string 180 ?x))))))
    (setf (chat-session-messages session) messages)
    (let ((prepared (chat-context-prepare-messages messages 100 session)))
      (should (chat-session-summaries session))
      (should
       (seq-find
        (lambda (message)
          (and (eq (chat-message-role message) :system)
               (string-match-p "Earlier conversation summary"
                               (chat-message-content message))))
        prepared))
      (should (equal (chat-message-id (car (last prepared))) "m8"))
      (should (< (length prepared) (length messages))))))

(ert-deftest chat-context-llm-compaction-persists-provider-summary ()
  "Test manual asynchronous compaction stores model-produced text."
  (let* ((chat-session-auto-save nil)
         (session (make-chat-session :id "llm-compact" :model-id 'kimi))
         (messages
          (cl-loop for index from 1 to 6
                   collect
                   (make-chat-message
                    :id (format "llm-%d" index)
                    :role (if (cl-oddp index) :user :assistant)
                    :content (make-string 160 (+ ?a index)))))
         stored)
    (setf (chat-session-messages session) messages)
    (cl-letf (((symbol-function 'chat-llm-request-async)
               (lambda (_model _messages success _error _options)
                 (funcall success '(:content "Durable model summary"))
                 'handle)))
      (chat-context-compact-session-with-llm
       session
       (lambda (entry) (setq stored entry))
       (lambda (message) (ert-fail message))
       80))
    (should stored)
    (should (equal (cdr (assoc 'summary stored))
                   "Durable model summary"))
    (should (equal (cdr (assoc 'kind
                               (cdr (assoc 'metadata stored))))
                   "llm"))))

(provide 'test-chat-context)
;;; test-chat-context.el ends here
