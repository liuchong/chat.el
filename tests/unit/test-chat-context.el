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

(ert-deftest chat-context-message-tokens-counts-typed-attachments ()
  "Images and files consume budget even though compatibility text is short."
  (let* ((image-digest (make-string 64 ?a))
         (file-digest (make-string 64 ?b))
         (chat-context-image-token-estimate 900)
         (image (chat-content-part-create
                 :type 'image :attachment-id image-digest :name "screen.png"
                 :mime-type "image/png" :size 100 :sha256 image-digest))
         (file (chat-content-part-create
                :type 'file :attachment-id file-digest :name "notes.txt"
                :mime-type "text/plain" :size 3000 :sha256 file-digest))
         (message (make-chat-message
                   :role :user :content "read"
                   :content-parts
                   (list (chat-content-text-part "read") image file))))
    (should (> (chat-context-message-tokens message) 1900))))

(ert-deftest chat-context-compaction-keeps-latest-attachment-part ()
  "Preparing an over-budget request preserves typed parts on the latest turn."
  (let* ((digest (make-string 64 ?c))
         (attachment
          (chat-content-part-create
           :type 'image :attachment-id digest :name "latest.png"
           :mime-type "image/png" :size 100 :sha256 digest))
         (messages
          (list (make-chat-message :role :user :content (make-string 500 ?a))
                (make-chat-message :role :assistant :content (make-string 500 ?b))
                (make-chat-message
                 :id "latest" :role :user :content "what is this"
                 :content-parts
                 (list (chat-content-text-part "what is this") attachment))))
         (prepared (chat-context-prepare-messages messages 400))
         (latest (car (last prepared))))
    (should (equal "latest" (chat-message-id latest)))
    (should (eq 'image
                (chat-content-part-type
                 (car (last (chat-message-parts latest))))))))

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

(ert-deftest chat-context-pre-compact-policy-can-refuse-with-an-audit-record ()
  "A refused compaction leaves history unchanged and records why."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (chat-session-wire--sequences (make-hash-table :test 'equal))
          (chat-session-wire--sizes (make-hash-table :test 'equal))
          (chat-session-wire-enabled t)
          (chat-event-blocking-types '(pre-compact))
          (chat-event-failure-policies '((pre-compact . fail-closed)))
          (chat-event-blocker-functions
           (list (lambda (_event)
                   '(:decision block :reason "keep full history"))))
          (session (make-chat-session :id "compact-blocked" :model-id 'kimi))
          (messages
           (cl-loop for index from 1 to 8
                    collect
                    (make-chat-message
                     :id (format "blocked-%d" index)
                     :role (if (cl-oddp index) :user :assistant)
                     :content (make-string 180 ?x)))))
     (setf (chat-session-messages session) messages)
     (should-not (chat-context-compact-session session 100))
     (should-not (chat-session-summaries session))
     (let* ((records (chat-session-wire-read "compact-blocked"))
            (pre (seq-find
                  (lambda (record)
                    (equal (alist-get 'kind record) "pre-compact"))
                  records)))
       (should pre)
       (should (equal "block" (alist-get 'event_decision pre)))
       (should (equal "keep full history" (alist-get 'event_reason pre)))
       (should-not
        (seq-find (lambda (record)
                    (equal (alist-get 'kind record) "post-compact"))
                  records))))))

(ert-deftest chat-context-llm-compaction-refusal-never-dispatches ()
  "A pre-compact refusal reports through the callback before transport."
  (let* ((chat-event-blocking-types '(pre-compact))
         (chat-event-failure-policies '((pre-compact . fail-closed)))
         (chat-event-blocker-functions
          (list (lambda (_event)
                  '(:decision block :reason "summary disabled"))))
         (session (make-chat-session :id "llm-blocked" :model-id 'kimi))
         (messages
          (cl-loop for index from 1 to 8
                   collect
                   (make-chat-message
                    :id (format "llm-blocked-%d" index)
                    :role (if (cl-oddp index) :user :assistant)
                    :content (make-string 180 ?x))))
         error)
    (setf (chat-session-messages session) messages)
    (cl-letf (((symbol-function 'chat-llm-request-async)
               (lambda (&rest _args)
                 (ert-fail "blocked compaction must not dispatch"))))
      (chat-context-compact-session-with-llm
       session #'ignore (lambda (message) (setq error message)) 100))
    (should (string-match-p "summary disabled" error))))

(ert-deftest chat-context-a-tool-result-is-counted-as-it-is-sent ()
  "The estimate was taken from the snippet a summary would show.

Snippets cap at 120 characters, and the request carries the tool result in
full, so a 100KB result counted as 30 tokens instead of 25,000.  Measured
on a 41-message coding session the context came out 8.4x under, which is
how auto-compaction comes to sit still while the payload passes the
provider's window."
  (let* ((result (make-string 100000 ?x))
         (msg (make-chat-message
               :id "a"
               :role :assistant
               :content ""
               :tool-calls '((:id "c1" :name "files_read"))
               :tool-results (list result)))
         (counted (chat-context-message-tokens msg)))
    ;; Within a hair of length/4, which is what the estimator claims to be.
    (should (> counted 24000))
    (should (< counted 26000))))

(ert-deftest chat-context-tool-call-arguments-are-counted-too ()
  "Arguments go on the wire as a string, or as JSON when they are not one."
  (let* ((written (make-string 40000 ?y))
         (as-string (make-chat-message
                     :id "a" :role :assistant :content ""
                     :tool-calls `((:id "c1" :name "files_write"
                                        :arguments ,written))))
         (as-data (make-chat-message
                   :id "b" :role :assistant :content ""
                   :tool-calls `((:id "c1" :name "files_write"
                                      :arguments ((path . "x")
                                                  (content . ,written)))))))
    (should (> (chat-context-message-tokens as-string) 9000))
    ;; The JSON form is longer, never shorter, since it adds the keys.
    (should (>= (chat-context-message-tokens as-data)
                (chat-context-message-tokens as-string)))))

(ert-deftest chat-context-a-summary-snippet-stays-a-snippet ()
  "Counting changed; summarizing did not.

The snippet is still capped, and it no longer collapses whitespace across
a whole file to keep 120 characters of it."
  (let* ((msg (make-chat-message
               :id "a" :role :assistant :content ""
               :tool-results (list (concat "head of it"
                                           (make-string 200000 ?\s)
                                           "tail nobody sees"))))
         (snippet (chat-context--tool-results-snippet msg)))
    (should (<= (string-width snippet) 120))
    (should (string-prefix-p "head of it" snippet))
    (should-not (string-match-p "tail nobody sees" snippet))))

(provide 'test-chat-context)
;;; test-chat-context.el ends here
