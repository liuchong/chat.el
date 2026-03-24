;;; test-chat-llm-kimi.el --- Tests for chat-llm-kimi.el -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: tests

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Unit tests for Kimi LLM provider implementation.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'test-helper)
(require 'chat-llm)

;; Skip tests if no API key available
(defun test-chat-kimi--has-api-key ()
  "Check if Kimi API key is available."
  (condition-case nil
      (chat-llm--get-api-key 'kimi)
    (error nil)))

;; ------------------------------------------------------------------
;; Provider Setup
;; ------------------------------------------------------------------

(ert-deftest chat-llm-kimi-is-registered ()
  "Test that Kimi provider is registered by default."
  (should (assoc 'kimi chat-llm-providers)))

(ert-deftest chat-llm-kimi-has-correct-base-url ()
  "Test that Kimi has correct API endpoint."
  (let ((config (chat-llm-get-provider 'kimi)))
    (should (string= (plist-get config :base-url)
                     "https://api.moonshot.cn/v1"))))

;; ------------------------------------------------------------------
;; Request Formatting
;; ------------------------------------------------------------------

(ert-deftest chat-llm-kimi-formats-request-correctly ()
  "Test Kimi-specific request formatting."
  (let* ((messages (list (make-chat-message :role :user :content "Hello Kimi")))
         (request (chat-llm--build-request 'kimi messages '(:temperature 0.7))))
    (should (equal (plist-get request :model) "moonshot-v1-8k"))
    (should (= (plist-get request :temperature) 0.7))
    (should (plist-get request :messages))
    (should (plist-get request :stream))))

;; ------------------------------------------------------------------
;; Response Parsing
;; ------------------------------------------------------------------

(ert-deftest chat-llm-kimi-parses-response-correctly ()
  "Test parsing Kimi API response."
  (let* ((json-data (list (cons 'choices
                                (vector (list (cons 'message
                                                    (list (cons 'content "Hello from Kimi")
                                                          (cons 'role "assistant"))))))))
         (parsed (chat-llm-kimi--parse-response json-data)))
    (should (string= parsed "Hello from Kimi"))))

(ert-deftest chat-llm-kimi-handles-stream-chunk ()
  "Test parsing Kimi stream chunk."
  (let* ((chunk (list (cons 'choices
                            (vector (list (cons 'delta
                                                (list (cons 'content " chunk"))))))))
         (parsed (chat-llm-kimi--parse-stream-chunk chunk)))
    (should (string= parsed " chunk"))))

;; ------------------------------------------------------------------
;; End-to-end Tests
;; ------------------------------------------------------------------

(ert-deftest chat-llm-kimi-simple-request ()
  "Test making a simple request to Kimi API.
Skipped in batch mode to avoid hanging tests."
  (skip-unless (not noninteractive))
  (skip-unless (test-chat-kimi--has-api-key))
  (let* ((messages (list (make-chat-message
                          :role :user
                          :content "Say hello in one word")))
         (response (chat-llm-request 'kimi messages '(:max-tokens 10))))
    (should (stringp response))
    (should (> (length response) 0))))

(ert-deftest chat-llm-kimi-streaming-request ()
  "Test streaming request to Kimi API.
Skipped in batch mode to avoid hanging tests."
  (skip-unless (not noninteractive))
  (skip-unless (test-chat-kimi--has-api-key))
  (let* ((messages (list (make-chat-message
                          :role :user
                          :content "Count 1 2 3")))
         (chunks '()))
    (chat-llm-stream 'kimi messages
                     (lambda (chunk)
                       (when chunk
                         (push chunk chunks))))
    (should (> (length chunks) 0))))

(provide 'test-chat-llm-kimi)
;;; test-chat-llm-kimi.el ends here
