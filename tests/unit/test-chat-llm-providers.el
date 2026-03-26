;;; test-chat-llm-providers.el --- Tests for provider variants -*- lexical-binding: t -*-
;; Copyright (C) 2026 chat.el contributors
;; Author: chat.el contributors
;; Keywords: tests
;;; Commentary:
;; Unit tests for additional provider registration and protocol adapters.
;;; Code:
(require 'ert)
(require 'test-helper)
(require 'chat-llm)
(require 'chat-llm-claude)
(require 'chat-llm-gemini)
(ert-deftest chat-llm-registers-mainstream-providers ()
  "Test that mainstream providers are registered."
  (dolist (provider '(openai kimi kimi-code deepseek qwen grok mistral glm doubao hunyuan minimax claude gemini))
    (should (assoc provider chat-llm-providers))))
(ert-deftest chat-llm-enabled-providers-filter-registry ()
  "Test enabled provider filter gates access without removing registration."
  (let ((chat-llm-enabled-providers '(kimi claude)))
    (should (chat-llm-provider-enabled-p 'kimi))
    (should-not (chat-llm-provider-enabled-p 'openai))
    (should (chat-llm-get-provider 'kimi))
    (should-not (chat-llm-get-provider 'openai))
    (should-error (chat-llm--ensure-provider 'openai))
    (should (equal (chat-llm-enabled-providers) '(claude kimi)))))
(ert-deftest chat-llm-request-url-supports-provider-specific-endpoints ()
  "Test provider specific request URL logic."
  (should (string= (chat-llm--request-url 'claude)
                   "https://api.anthropic.com/v1/messages"))
  (should (string= (chat-llm--request-url 'gemini)
                   "https://generativelanguage.googleapis.com/v1/models/gemini-2.5-flash:generateContent"))
  (should (string= (chat-llm--request-url 'gemini '(:stream t))
                   "https://generativelanguage.googleapis.com/v1/models/gemini-2.5-flash:streamGenerateContent?alt=sse")))
(ert-deftest chat-llm-custom-auth-headers-support-non-bearer-providers ()
  "Test custom auth headers for Claude and Gemini."
  (let ((chat-llm-claude-api-key "claude-key")
        (chat-llm-gemini-api-key "gemini-key"))
    (should (equal (cdr (assoc "x-api-key" (chat-llm--make-headers 'claude)))
                   "claude-key"))
    (should (equal (cdr (assoc "anthropic-version" (chat-llm--make-headers 'claude)))
                   chat-llm-claude-api-version))
    (should (equal (cdr (assoc "x-goog-api-key" (chat-llm--make-headers 'gemini)))
                   "gemini-key"))
    (should-not (assoc "Authorization" (chat-llm--make-headers 'gemini)))))
(ert-deftest chat-llm-claude-builds-messages-api-request ()
  "Test Claude request builder maps system and chat messages correctly."
  (let* ((messages (list (make-chat-message :role :system :content "System rule")
                         (make-chat-message :role :user :content "Hello")
                         (make-chat-message :role :assistant :content "Hi")))
         (request (chat-llm-claude--build-request messages '(:stream t))))
    (should (equal (plist-get request :model) "claude-sonnet-4-5"))
    (should (equal (plist-get request :system) "System rule"))
    (should (= (length (plist-get request :messages)) 2))
    (should (plist-get request :stream))))
(ert-deftest chat-llm-claude-parses-text-blocks ()
  "Test Claude response parser concatenates text blocks."
  (let ((json-data '((content . [((type . "text") (text . "Hello"))
                                 ((type . "text") (text . " Claude"))]))))
    (should (string= (chat-llm-claude--parse-response json-data)
                     "Hello Claude"))))
(ert-deftest chat-llm-gemini-builds-generate-content-request ()
  "Test Gemini request builder maps messages and system instruction."
  (let* ((messages (list (make-chat-message :role :system :content "You are precise")
                         (make-chat-message :role :user :content "Hello")))
         (request (chat-llm-gemini--build-request messages '(:temperature 0.2))))
    (should (plist-get request :systemInstruction))
    (should (= (length (plist-get request :contents)) 1))
    (should (= (plist-get (plist-get request :generationConfig) :temperature) 0.2))))
(ert-deftest chat-llm-gemini-parses-candidate-parts ()
  "Test Gemini response parser joins candidate text parts."
  (let ((json-data '((candidates . [((content . ((parts . [((text . "Hello"))
                                                            ((text . " Gemini"))]))))]))))
    (should (string= (chat-llm-gemini--parse-response json-data)
                     "Hello Gemini"))))
(provide 'test-chat-llm-providers)
;;; test-chat-llm-providers.el ends here
