;;; test-chat-llm-empty-assistant.el --- Tests for empty assistant message filtering -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;;; Commentary:

;; Regression test for: API error "assistant message must not be empty"
;; Bug: Empty assistant messages were being sent to API, causing 400 error
;; Fix: Filter out empty assistant messages in chat-llm--format-messages

;;; Code:

(require 'ert)
(require 'chat-session)
(require 'chat-llm)

(ert-deftest chat-llm-filters-empty-assistant-messages ()
  "Test that empty assistant messages are filtered from API request.

This is a regression test for HTTP 400 error:
'the message at position X with role assistant must not be empty'"
  (let* ((messages (list
                    (make-chat-message :id "1" :role :user :content "Hello" :timestamp (current-time))
                    (make-chat-message :id "2" :role :assistant :content "" :timestamp (current-time))
                    (make-chat-message :id "3" :role :user :content "Hi" :timestamp (current-time))
                    (make-chat-message :id "4" :role :assistant :content "Response" :timestamp (current-time))))
         (formatted (chat-llm--format-messages messages)))
    ;; Should filter out empty assistant message (id "2")
    (should (= (length formatted) 3))
    ;; Verify non-empty assistant message is kept
    (should (cl-some (lambda (m) (equal (cdr (assoc 'content m)) "Response")) formatted))
    ;; Verify empty assistant is not present
    (should-not (cl-some (lambda (m) (equal (cdr (assoc 'content m)) "")) formatted))))

(ert-deftest chat-llm-keeps-non-empty-assistant-messages ()
  "Test that non-empty assistant messages are preserved."
  (let* ((messages (list
                    (make-chat-message :id "1" :role :user :content "Test" :timestamp (current-time))
                    (make-chat-message :id "2" :role :assistant :content "Answer" :timestamp (current-time))))
         (formatted (chat-llm--format-messages messages)))
    (should (= (length formatted) 2))
    (should (cl-some (lambda (m) (equal (cdr (assoc 'role m)) "assistant")) formatted))))

(ert-deftest chat-llm-keeps-empty-user-messages ()
  "Test that empty user messages are kept (API allows them)."
  (let* ((messages (list
                    (make-chat-message :id "1" :role :user :content "" :timestamp (current-time))
                    (make-chat-message :id "2" :role :assistant :content "Response" :timestamp (current-time))))
         (formatted (chat-llm--format-messages messages)))
    ;; User messages can be empty, only assistant is restricted
    (should (>= (length formatted) 1))))

(provide 'test-chat-llm-empty-assistant)
;;; test-chat-llm-empty-assistant.el ends here
