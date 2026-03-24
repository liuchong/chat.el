;;; chat-llm.el --- LLM API abstraction layer -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: llm, api, ai

;; This file is not part of GNU Emacs.

;;; Commentary:

;; This module provides an abstraction layer for LLM API providers.
;; It supports multiple providers with a unified interface.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'url)

;; ------------------------------------------------------------------
;; Provider Registry
;; ------------------------------------------------------------------

(defvar chat-llm-providers nil
  "Alist of registered LLM providers.
Each entry is a pair of (SYMBOL . CONFIG-PLIST).")

(defun chat-llm-register-provider (symbol &rest config)
  "Register a new LLM provider with SYMBOL and CONFIG.

CONFIG is a plist with keys:
  :name - Display name
  :base-url - API base URL
  :api-key - API key string
  :api-key-fn - Function to retrieve API key
  :model - Default model name
  :headers - Additional HTTP headers
  :request-fn - Function to build request payload
  :response-fn - Function to parse response"
  (setq chat-llm-providers
        (cons (cons symbol config)
              (assq-delete-all symbol chat-llm-providers))))

(defun chat-llm-get-provider (symbol)
  "Get configuration for provider SYMBOL."
  (cdr (assoc symbol chat-llm-providers)))

;; ------------------------------------------------------------------
;; API Key Management
;; ------------------------------------------------------------------

(defun chat-llm--get-api-key (provider)
  "Get API key for PROVIDER.

Checks in order:
1. api-key-fn from config
2. api-key from config
3. auth-source lookup"
  (let ((config (chat-llm-get-provider provider)))
    (or (when-let ((fn (plist-get config :api-key-fn)))
          (funcall fn))
        (plist-get config :api-key)
        (chat-llm--auth-source-lookup provider))))

(defun chat-llm--auth-source-lookup (provider)
  "Look up API key for PROVIDER in auth-source."
  (when (require 'auth-source nil t)
    (let ((result (auth-source-search
                   :host (format "%s-api" provider)
                   :user "api-key"
                   :require '(:secret)
                   :max 1)))
      (when result
        (let ((secret (plist-get (car result) :secret)))
          (if (functionp secret)
              (funcall secret)
            secret))))))

;; ------------------------------------------------------------------
;; Request Building
;; ------------------------------------------------------------------

(defun chat-llm--format-messages (messages)
  "Convert chat MESSAGE structs to API format."
  (mapcar (lambda (msg)
            (let ((role (chat-message-role msg)))
              (list :role (if (keywordp role)
                             (substring (symbol-name role) 1)
                           (symbol-name role))
                    :content (chat-message-content msg))))
          messages))

(defun chat-llm--build-request (provider messages options)
  "Build request payload for PROVIDER with MESSAGES and OPTIONS."
  (let* ((config (chat-llm-get-provider provider))
         (model (or (plist-get options :model)
                    (plist-get config :model)))
         (temperature (or (plist-get options :temperature) 0.7))
         (max-tokens (plist-get options :max-tokens))
         (stream (or (plist-get options :stream) t)))
    (list :model model
          :messages (chat-llm--format-messages messages)
          :temperature temperature
          :stream stream
          :max_tokens max-tokens)))

;; ------------------------------------------------------------------
;; HTTP Utilities
;; ------------------------------------------------------------------

(defun chat-llm--make-headers (provider)
  "Generate HTTP headers for PROVIDER."
  (let* ((config (chat-llm-get-provider provider))
         (api-key (chat-llm--get-api-key provider))
         (extra-headers (plist-get config :headers)))
    (append
     (list (cons "Content-Type" "application/json")
           (cons "Authorization" (format "Bearer %s" api-key)))
     extra-headers)))

(defun chat-llm--post (url headers body callback error-callback)
  "Make async POST request to URL.

HEADERS is an alist of HTTP headers.
BODY is the request body string.
CALLBACK is called with response body on success.
ERROR-CALLBACK is called with error message on failure."
  (let ((url-request-method "POST")
        (url-request-extra-headers headers)
        (url-request-data body))
    (url-retrieve
     url
     (lambda (status)
       (if (plist-get status :error)
           (funcall error-callback
                    (format "HTTP error: %s" (plist-get status :error)))
         (goto-char (point-min))
         (re-search-forward "\n\n" nil t)
         (let ((body (buffer-substring (point) (point-max))))
           (funcall callback body))
         (kill-buffer (current-buffer))))
     nil
     t)))

;; ------------------------------------------------------------------
;; Main API
;; ------------------------------------------------------------------

(defun chat-llm-request (provider messages &optional options)
  "Send request to PROVIDER with MESSAGES.

PROVIDER is a symbol identifying the provider.
MESSAGES is a list of chat-message structs.
OPTIONS is an optional plist of request parameters.

Returns the response content string."
  (let* ((config (chat-llm-get-provider provider))
         (base-url (plist-get config :base-url))
         (request-body (chat-llm--build-request provider messages options))
         (headers (chat-llm--make-headers provider))
         (response nil)
         (error-msg nil)
         (done nil))
    (chat-llm--post
     (concat base-url "/chat/completions")
     headers
     (json-encode request-body)
     (lambda (body)
       (condition-case err
           (let* ((json-data (json-read-from-string body))
                  (parser (or (plist-get config :response-fn)
                              #'chat-llm--default-parse-response))
                  (content (funcall parser json-data)))
             (setq response content
                   done t))
         (error
          (setq error-msg (format "Parse error: %s" (error-message-string err))
                done t))))
     (lambda (err)
       (setq error-msg err
             done t)))
    ;; Wait for async response with timeout
    (with-timeout (30 (error "Request timeout"))
      (while (not done)
        (sit-for 0.1)))
    (if error-msg
        (error error-msg)
      response)))

(defun chat-llm-stream (provider messages callback &optional options)
  "Stream response from PROVIDER with MESSAGES to CALLBACK.

CALLBACK is called with each chunk of the response.
OPTIONS is an optional plist of request parameters."
  (let* ((config (chat-llm-get-provider provider))
         (base-url (plist-get config :base-url))
         (opts (plist-put (copy-tree options) :stream t))
         (request-body (chat-llm--build-request provider messages opts))
         (headers (chat-llm--make-headers provider))
         (process nil)
         (buffer (generate-new-buffer " *chat-llm-stream*")))
    ;; This is a simplified streaming implementation
    ;; Full implementation would use process filters for SSE
    (chat-llm--post
     (concat base-url "/chat/completions")
     headers
     (json-encode request-body)
     (lambda (body)
       ;; For non-streaming fallback
       (let* ((json-data (json-read-from-string body))
              (parser (or (plist-get config :response-fn)
                          #'chat-llm--default-parse-response))
              (content (funcall parser json-data)))
         (funcall callback content)
         (funcall callback nil)))
     (lambda (err)
       (funcall callback nil)
       (error err)))))

(defun chat-llm--default-parse-response (json-data)
  "Default response parser for JSON-DATA."
  (let* ((choices (cdr (assoc 'choices json-data)))
         (first-choice (aref choices 0))
         (message (cdr (assoc 'message first-choice)))
         (content (cdr (assoc 'content message))))
    content))

;; ------------------------------------------------------------------
;; Provider Implementations
;; ------------------------------------------------------------------

;; Default providers will be defined in separate files
;; chat-llm-kimi.el, chat-llm-openai.el, etc.

(provide 'chat-llm)
;;; chat-llm.el ends here
