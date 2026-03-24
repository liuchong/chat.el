;;; chat-llm-openai.el --- OpenAI LLM provider for chat.el -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: llm, openai, gpt

;; This file is not part of GNU Emacs.

;;; Commentary:

;; This module provides integration with OpenAI's API.
;; Supports GPT-4o, GPT-4o-mini, and other OpenAI models.

;;; Code:

(require 'chat-llm)

;; ------------------------------------------------------------------
;; Configuration
;; ------------------------------------------------------------------

(defgroup chat-llm-openai nil
  "OpenAI LLM provider configuration."
  :group 'chat-llm)

(defcustom chat-llm-openai-default-model "gpt-4o"
  "Default OpenAI model to use."
  :type 'string
  :group 'chat-llm-openai)

(defcustom chat-llm-openai-api-key nil
  "API key for OpenAI.
If nil, will try to lookup from auth-source or chat-llm-openai-api-key-fn."
  :type '(choice (const :tag "Use auth-source" nil)
                 (string :tag "API Key"))
  :group 'chat-llm-openai)

(defcustom chat-llm-openai-api-key-fn nil
  "Function to retrieve OpenAI API key."
  :type '(choice (const :tag "None" nil)
                 (function :tag "Key function"))
  :group 'chat-llm-openai)

;; ------------------------------------------------------------------
;; Provider Setup
;; ------------------------------------------------------------------

(defun chat-llm-openai--get-api-key ()
  "Get OpenAI API key from configuration."
  (or chat-llm-openai-api-key
      (when chat-llm-openai-api-key-fn
        (funcall chat-llm-openai-api-key-fn))
      (chat-llm--auth-source-lookup 'openai)))

(defun chat-llm-openai--build-request (messages options)
  "Build OpenAI-specific request with MESSAGES and OPTIONS."
  (let* ((model (or (plist-get options :model)
                    chat-llm-openai-default-model))
         (temperature (or (plist-get options :temperature) 0.7))
         (max-tokens (or (plist-get options :max-tokens) 2048))
         (stream (if (plist-member options :stream)
                     (plist-get options :stream)
                   t)))
    (list :model model
          :messages (chat-llm--format-messages messages)
          :temperature temperature
          :max_tokens max-tokens
          :stream stream)))

(defun chat-llm-openai--parse-response (json-data)
  "Parse OpenAI API JSON-DATA response."
  (let* ((choices (cdr (assoc 'choices json-data)))
         (first-choice (aref choices 0))
         (message (cdr (assoc 'message first-choice)))
         (content (cdr (assoc 'content message))))
    content))

;; ------------------------------------------------------------------
;; Provider Registration
;; ------------------------------------------------------------------

(chat-llm-register-provider
 'openai
 :name "OpenAI"
 :base-url "https://api.openai.com/v1"
 :api-key-fn #'chat-llm-openai--get-api-key
 :model chat-llm-openai-default-model
 :request-fn #'chat-llm-openai--build-request
 :response-fn #'chat-llm-openai--parse-response)

(provide 'chat-llm-openai)
;;; chat-llm-openai.el ends here
