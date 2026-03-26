;;; chat-llm-kimi.el --- Kimi LLM provider for chat.el -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: llm, kimi, moonshot

;; This file is not part of GNU Emacs.

;;; Commentary:

;; This module provides integration with Moonshot AI's Kimi API.
;; Register your API key via auth-source or custom configuration.

;;; Code:

(require 'chat-llm)

;; ------------------------------------------------------------------
;; Configuration
;; ------------------------------------------------------------------

(defgroup chat-llm-kimi nil
  "Kimi LLM provider configuration."
  :group 'chat-llm)

(defcustom chat-llm-kimi-default-model "moonshot-v1-8k"
  "Default Kimi model to use."
  :type 'string
  :group 'chat-llm-kimi)

(defcustom chat-llm-kimi-api-key nil
  "API key for Kimi.
If nil, will try to lookup from auth-source or chat-llm-kimi-api-key-fn."
  :type '(choice (const :tag "Use auth-source" nil)
                 (string :tag "API Key"))
  :group 'chat-llm-kimi)

(defcustom chat-llm-kimi-api-key-fn nil
  "Function to retrieve Kimi API key.
Called with no arguments, should return the API key string."
  :type '(choice (const :tag "None" nil)
                 (function :tag "Key function"))
  :group 'chat-llm-kimi)

;; ------------------------------------------------------------------
;; Provider Setup
;; ------------------------------------------------------------------

(defun chat-llm-kimi--get-api-key ()
  "Get Kimi API key from configuration."
  (or chat-llm-kimi-api-key
      (when chat-llm-kimi-api-key-fn
        (funcall chat-llm-kimi-api-key-fn))
      (chat-llm--auth-source-lookup 'kimi (chat-llm-get-provider-config 'kimi))))

;; ------------------------------------------------------------------
;; Provider Registration
;; ------------------------------------------------------------------

(chat-llm-register-openai-compatible-provider
 'kimi
 "Kimi"
 "https://api.moonshot.cn/v1"
 chat-llm-kimi-default-model
 :api-key-fn #'chat-llm-kimi--get-api-key
 :max-output-tokens 2048)

;; Parser functions are available directly via provide

(provide 'chat-llm-kimi)
;;; chat-llm-kimi.el ends here
