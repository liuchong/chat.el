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
      (chat-llm--auth-source-lookup 'kimi)))

(defun chat-llm-kimi--build-request (messages options)
  "Build Kimi-specific request with MESSAGES and OPTIONS."
  (let* ((model (or (plist-get options :model)
                    chat-llm-kimi-default-model))
         (temperature (or (plist-get options :temperature) 0.7))
         (max-tokens (or (plist-get options :max-tokens) 2048))
         (stream (plist-get options :stream)))
    (list :model model
          :messages (chat-llm--format-messages messages)
          :temperature temperature
          :max_tokens max-tokens
          :stream stream)))

(defun chat-llm-kimi--parse-response (json-data)
  "Parse Kimi API JSON-DATA response."
  ;; Check for API error response
  (when-let ((error-obj (cdr (assoc 'error json-data))))
    (let ((err-msg (cdr (assoc 'message error-obj)))
          (err-type (cdr (assoc 'type error-obj))))
      (error "Kimi API error: %s (%s)" (or err-msg "Unknown") (or err-type "unknown"))))
  ;; Parse normal response
  (let* ((choices (cdr (assoc 'choices json-data)))
         (first-choice (and choices (aref choices 0)))
         (message (and first-choice (cdr (assoc 'message first-choice))))
         (content (and message (cdr (assoc 'content message)))))
    (unless content
      (error "Unexpected response format: %s" 
             (json-encode json-data)))
    content))

(defun chat-llm-kimi--parse-stream-chunk (json-data)
  "Parse a Kimi streaming chunk JSON-DATA."
  (let* ((choices (cdr (assoc 'choices json-data)))
         (first-choice (aref choices 0))
         (delta (cdr (assoc 'delta first-choice)))
         (content (cdr (assoc 'content delta))))
    content))

;; ------------------------------------------------------------------
;; Provider Registration
;; ------------------------------------------------------------------

(chat-llm-register-provider
 'kimi
 :name "Kimi"
 :base-url "https://api.moonshot.cn/v1"
 :api-key-fn #'chat-llm-kimi--get-api-key
 :model chat-llm-kimi-default-model
 :request-fn #'chat-llm-kimi--build-request
 :response-fn #'chat-llm-kimi--parse-response
 :stream-fn #'chat-llm-kimi--parse-stream-chunk)

;; Parser functions are available directly via provide

(provide 'chat-llm-kimi)
;;; chat-llm-kimi.el ends here
