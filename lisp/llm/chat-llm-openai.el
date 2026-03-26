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
      (chat-llm--auth-source-lookup 'openai (chat-llm-get-provider-config 'openai))))

;; ------------------------------------------------------------------
;; Provider Registration
;; ------------------------------------------------------------------

(chat-llm-register-openai-compatible-provider
 'openai
 "OpenAI"
 "https://api.openai.com/v1"
 chat-llm-openai-default-model
 :api-key-fn #'chat-llm-openai--get-api-key
 :max-output-tokens 2048)

(provide 'chat-llm-openai)
;;; chat-llm-openai.el ends here
