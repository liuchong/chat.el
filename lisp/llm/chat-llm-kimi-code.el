;;; chat-llm-kimi-code.el --- Kimi Code China provider for chat.el -*- lexical-binding: t -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;; Author: Your Name
;; Keywords: tools, convenience

;; This file is part of chat.el.

;;; Commentary:

;; Kimi Code China provider configuration.
;; API documentation: https://www.kimi.com/code/docs/more/third-party-agents.html

;;; Code:

(require 'chat-llm)

;; ------------------------------------------------------------------
;; Configuration
;; ------------------------------------------------------------------

(defgroup chat-llm-kimi-code nil
  "Kimi Code China provider for chat.el."
  :group 'chat)

(defcustom chat-llm-kimi-code-api-key nil
  "API key for Kimi Code China.
Get your key from: https://www.kimi.com/code"
  :type '(choice (string :tag "API Key")
                 (function :tag "Function returning API key"))
  :group 'chat-llm-kimi-code)

(defcustom chat-llm-kimi-code-api-key-fn nil
  "Function to retrieve Kimi Code API key dynamically."
  :type '(choice (const nil) function)
  :group 'chat-llm-kimi-code)

(defcustom chat-llm-kimi-code-default-model "kimi-for-coding"
  "Default model for Kimi Code China."
  :type 'string
  :group 'chat-llm-kimi-code)

;; ------------------------------------------------------------------
;; Provider Implementation
;; ------------------------------------------------------------------

(defun chat-llm-kimi-code--get-api-key ()
  "Get Kimi Code API key from configuration."
  (or chat-llm-kimi-code-api-key
      (when chat-llm-kimi-code-api-key-fn
        (funcall chat-llm-kimi-code-api-key-fn))
      (chat-llm--auth-source-lookup 'kimi-code
                                    (chat-llm-get-provider-config 'kimi-code))))

(defun chat-llm-kimi-code--build-request (messages options)
  "Build Kimi Code request with MESSAGES and OPTIONS.

Uses OpenAI-compatible format."
  (let* ((model (or (plist-get options :model)
                    chat-llm-kimi-code-default-model))
         (temperature (or (plist-get options :temperature) 0.7))
         (max-tokens (or (plist-get options :max-tokens) 32768))
         (stream (plist-get options :stream)))
    `((model . ,model)
      (messages . ,(chat-llm--format-messages messages))
      (temperature . ,temperature)
      (max_tokens . ,max-tokens)
      ,@(when stream `((stream . ,stream))))))

(defun chat-llm-kimi-code--parse-response (json-data)
  "Parse Kimi Code API JSON-DATA response.

Handles OpenAI-compatible response format."
  ;; Check for API error response
  (when-let ((error-obj (cdr (assoc 'error json-data))))
    (let ((err-msg (cdr (assoc 'message error-obj)))
          (err-type (cdr (assoc 'type error-obj))))
      (error "Kimi Code API error: %s (%s)"
             (or err-msg "Unknown")
             (or err-type "unknown"))))
  ;; Parse normal response
  (let* ((choices (cdr (assoc 'choices json-data)))
         (first-choice (and choices
                            (if (vectorp choices)
                                (aref choices 0)
                              (car choices))))
         (message (and first-choice (cdr (assoc 'message first-choice))))
         (content (and message (cdr (assoc 'content message)))))
    (unless content
      (error "Unexpected response format: %s"
             (json-encode json-data)))
    content))

(defun chat-llm-kimi-code--parse-stream-chunk (json-data)
  "Parse a Kimi Code streaming chunk JSON-DATA.

Uses OpenAI-compatible streaming format."
  (let* ((choices (cdr (assoc 'choices json-data)))
         (first-choice (and choices
                            (if (vectorp choices)
                                (aref choices 0)
                              (car choices))))
         (delta (and first-choice (cdr (assoc 'delta first-choice))))
         (content (and delta (cdr (assoc 'content delta)))))
    content))

;; ------------------------------------------------------------------
;; Custom Headers
;; ------------------------------------------------------------------

(defun chat-llm-kimi-code--headers ()
  "Generate headers for Kimi Code API.

Kimi Code API requires User-Agent from an approved coding agent.
Reference: https://www.kimi.com/code/docs/more/third-party-agents.html"
  ;; Using claude-code User-Agent as it's a documented compatible agent.
  ;; The User-Agent must be passed through url-request-extra-headers, not
  ;; the url-user-agent variable.
  '(("User-Agent" . "claude-code/0.1.0")
    ("Accept" . "application/json")))

;; ------------------------------------------------------------------
;; Provider Registration
;; ------------------------------------------------------------------

(chat-llm-register-provider
 'kimi-code
 :name "Kimi Code"
 :base-url "https://api.kimi.com/coding/v1"
 :async-transport 'curl
 :api-key-fn #'chat-llm-kimi-code--get-api-key
 :model chat-llm-kimi-code-default-model
 :context-window 262144
 :max-output-tokens 32768
 :headers #'chat-llm-kimi-code--headers
 :build-request-fn #'chat-llm-kimi-code--build-request
 :response-fn #'chat-llm-kimi-code--parse-response
 :stream-fn #'chat-llm-kimi-code--parse-stream-chunk)

(provide 'chat-llm-kimi-code)
;;; chat-llm-kimi-code.el ends here
