;;; test-chat-llm-openai.el --- Tests for OpenAI provider -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: tests

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Unit tests for OpenAI LLM provider implementation.

;;; Code:

(require 'ert)
(require 'test-helper)
(require 'chat-llm)

(ert-deftest chat-llm-openai-is-registered ()
  "Test that OpenAI provider is registered by default."
  (should (assoc 'openai chat-llm-providers)))

(ert-deftest chat-llm-openai-has-correct-base-url ()
  "Test that OpenAI has correct API endpoint."
  (let ((config (chat-llm-get-provider 'openai)))
    (should (string= (plist-get config :base-url)
                     "https://api.openai.com/v1"))))

(ert-deftest chat-llm-openai-formats-request-correctly ()
  "Test OpenAI-specific request formatting."
  (let* ((messages (list (make-chat-message :role :user :content "Hello")))
         (request (chat-llm--build-request 'openai messages '(:temperature 0.8))))
    (should (equal (plist-get request :model) "gpt-4o"))
    (should (= (plist-get request :temperature) 0.8))
    (should (plist-get request :messages))))

(provide 'test-chat-llm-openai)
;;; test-chat-llm-openai.el ends here
