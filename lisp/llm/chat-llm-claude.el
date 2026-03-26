;;; chat-llm-claude.el --- Claude provider for chat.el -*- lexical-binding: t -*-
;; Copyright (C) 2026 chat.el contributors
;; Author: chat.el contributors
;; Keywords: llm, claude, anthropic
;;; Commentary:
;; This module provides integration with the official Claude Messages API.
;;; Code:
(require 'chat-llm)
(defgroup chat-llm-claude nil
  "Claude provider configuration."
  :group 'chat-llm)
(defcustom chat-llm-claude-default-model "claude-sonnet-4-5"
  "Default Claude model to use."
  :type 'string
  :group 'chat-llm-claude)
(defcustom chat-llm-claude-api-key nil
  "API key for Claude."
  :type '(choice (const :tag "Use auth-source" nil)
                 (string :tag "API key"))
  :group 'chat-llm-claude)
(defcustom chat-llm-claude-api-key-fn nil
  "Function to retrieve Claude API key."
  :type '(choice (const :tag "None" nil)
                 (function :tag "Key function"))
  :group 'chat-llm-claude)
(defcustom chat-llm-claude-api-version "2023-06-01"
  "Claude API version header."
  :type 'string
  :group 'chat-llm-claude)
(defun chat-llm-claude--get-api-key ()
  "Get Claude API key from configuration."
  (or chat-llm-claude-api-key
      (when chat-llm-claude-api-key-fn
        (funcall chat-llm-claude-api-key-fn))
      (chat-llm--auth-source-lookup 'claude
                                    (chat-llm-get-provider-config 'claude))))
(defun chat-llm-claude--auth-headers (api-key _provider _config)
  "Build Claude auth headers from API-KEY."
  (list (cons "x-api-key" api-key)
        (cons "anthropic-version" chat-llm-claude-api-version)))
(defun chat-llm-claude--message-role (role)
  "Map internal ROLE to a Claude role string."
  (if (eq role :assistant)
      "assistant"
    "user"))
(defun chat-llm-claude--build-request (messages options)
  "Build Claude request with MESSAGES and OPTIONS."
  (let ((system-lines nil)
        (normal-messages nil))
    (dolist (msg messages)
      (let ((role (chat-message-role msg))
            (content (or (chat-message-content msg) "")))
        (when (not (string-empty-p content))
          (if (eq role :system)
              (push content system-lines)
            (push `((role . ,(chat-llm-claude--message-role role))
                    (content . ,content))
                  normal-messages)))))
    (let ((request
           (list :model (or (plist-get options :model)
                            chat-llm-claude-default-model)
                 :messages (vconcat (nreverse normal-messages))
                 :max_tokens (or (plist-get options :max-tokens) 4096)
                 :temperature (or (plist-get options :temperature) 0.7)
                 :stream (plist-get options :stream))))
      (when system-lines
        (setq request
              (plist-put request :system
                         (mapconcat #'identity (nreverse system-lines) "\n\n"))))
      request)))
(defun chat-llm-claude--parse-response (json-data)
  "Parse Claude response JSON-DATA."
  (when-let ((error-obj (cdr (assoc 'error json-data))))
    (error "Claude API error: %s"
           (or (cdr (assoc 'message error-obj))
               (json-encode error-obj))))
  (let ((blocks (cdr (assoc 'content json-data)))
        (texts nil))
    (dolist (block (if (vectorp blocks) (append blocks nil) blocks))
      (when (string= (cdr (assoc 'type block)) "text")
        (push (cdr (assoc 'text block)) texts)))
    (unless texts
      (error "Unexpected Claude response format: %s" (json-encode json-data)))
    (mapconcat #'identity (nreverse texts) "")))
(defun chat-llm-claude--parse-stream-chunk (json-data)
  "Parse Claude stream chunk JSON-DATA."
  (let ((delta (cdr (assoc 'delta json-data))))
    (or (cdr (assoc 'text delta))
        (cdr (assoc 'text (cdr (assoc 'content_block json-data)))))))
(chat-llm-register-provider
 'claude
 :name "Claude"
 :base-url "https://api.anthropic.com"
 :request-path "/v1/messages"
 :api-key-fn #'chat-llm-claude--get-api-key
 :auth-headers-fn #'chat-llm-claude--auth-headers
 :model chat-llm-claude-default-model
 :request-fn #'chat-llm-claude--build-request
 :response-fn #'chat-llm-claude--parse-response
 :stream-fn #'chat-llm-claude--parse-stream-chunk)
(provide 'chat-llm-claude)
;;; chat-llm-claude.el ends here
