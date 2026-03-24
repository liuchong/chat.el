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
(require 'chat-log)

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
  (vconcat
   (mapcar (lambda (msg)
             (let ((role (chat-message-role msg)))
               `((role . ,(if (keywordp role)
                             (substring (symbol-name role) 1)
                           (symbol-name role)))
                 (content . ,(chat-message-content msg)))))
           messages)))

(defun chat-llm--build-request (provider messages options)
  "Build request payload for PROVIDER with MESSAGES and OPTIONS."
  (let* ((config (chat-llm-get-provider provider))
         (model (or (plist-get options :model)
                    (plist-get config :model)))
         (temperature (or (plist-get options :temperature) 0.7))
         (max-tokens (plist-get options :max-tokens))
         (stream (plist-get options :stream)))
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
         (extra-headers-raw (plist-get config :headers))
         (extra-headers (if (functionp extra-headers-raw)
                            (funcall extra-headers-raw)
                          extra-headers-raw)))
    (append
     (list (cons "Content-Type" "application/json")
           (cons "Authorization" (format "Bearer %s" api-key)))
     extra-headers)))

(defun chat-llm--post-sync (url headers body timeout-secs)
  "Make synchronous POST request to URL with TIMEOUT-SECS.

HEADERS is an alist of HTTP headers.
BODY is the request body string.
Returns (BODY . STATUS-CODE) on success, or signals error on failure."
  (chat-log "[LLM] POST to %s" url)
  (chat-log "[LLM] Body length: %d bytes" (length body))
  (let ((url-request-method "POST")
        (url-request-extra-headers headers)
        (url-request-data body)
        ;; Extract User-Agent from headers if present
        (url-user-agent (or (cdr (assoc "User-Agent" headers))
                            "chat.el/1.0"))
        response-buffer status-code response-body)
    (chat-log "[LLM] Headers: %S" headers)
    (chat-log "[LLM] User-Agent: %s" url-user-agent)
    (condition-case err
        (progn
          (setq response-buffer 
                (with-timeout (timeout-secs (error "Request timeout after %d seconds" timeout-secs))
                  (url-retrieve-synchronously url nil t timeout-secs)))
          (when response-buffer
            (unwind-protect
                (with-current-buffer response-buffer
                  (goto-char (point-min))
                  ;; Parse HTTP status
                  (when (looking-at "HTTP/[^ ]+ \\([0-9]+\\)")
                    (setq status-code (string-to-number (match-string 1)))
                    (chat-log "[LLM] HTTP status code: %d" status-code))
                  ;; Extract body
                  (if (re-search-forward "\n\n" nil t)
                      (setq response-body (buffer-substring (point) (point-max)))
                    (setq response-body ""))
                  (chat-log "[LLM] Response body length: %d bytes" (length response-body))
                  (cons response-body status-code))
              (kill-buffer response-buffer))))
      (error
       (when response-buffer (kill-buffer response-buffer))
       (signal (car err) (cdr err))))))

;; ------------------------------------------------------------------
;; Main API
;; ------------------------------------------------------------------

(defun chat-llm-request (provider messages &optional options)
  "Send request to PROVIDER with MESSAGES.

PROVIDER is a symbol identifying the provider.
MESSAGES is a list of chat-message structs.
OPTIONS is an optional plist of request parameters.

Returns a plist with :content, :raw-request and :raw-response."
  (chat-log "[LLM] Starting request to provider: %s" provider)
  (let* ((config (chat-llm-get-provider provider))
         (base-url (plist-get config :base-url))
         (request-body (chat-llm--build-request provider messages options))
         (headers (chat-llm--make-headers provider))
         (timeout (or (plist-get options :timeout) 60))
         (raw-request (json-encode request-body)))
    (chat-log "[LLM] Base URL: %s" base-url)
    (chat-log "[LLM] Request body: %s" raw-request)
    (chat-log "[LLM] Headers present: %s" (if headers "yes" "no"))
    ;; Synchronous request
    (let* ((result (chat-llm--post-sync
                    (concat base-url "/chat/completions")
                    headers
                    raw-request
                    timeout))
           (raw-response (car result))
           (status-code (cdr result))
           (parser (or (plist-get config :response-fn)
                       #'chat-llm--default-parse-response)))
      (chat-log "[LLM] Got response body: %s..." (substring raw-response 0 (min 100 (length raw-response))))
      (if (/= status-code 200)
          (error "HTTP error %d: %s" status-code raw-response)
        (let ((json-data (json-read-from-string raw-response)))
          (list :content (funcall parser json-data)
                :raw-request raw-request
                :raw-response raw-response))))))

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
  ;; Check for API error response
  (when-let ((error-obj (cdr (assoc 'error json-data))))
    (let ((err-msg (cdr (assoc 'message error-obj)))
          (err-type (cdr (assoc 'type error-obj))))
      (error "API error: %s (%s)" (or err-msg "Unknown") (or err-type "unknown"))))
  ;; Parse normal response
  (let* ((choices (cdr (assoc 'choices json-data)))
         (first-choice (and choices (aref choices 0)))
         (message (and first-choice (cdr (assoc 'message first-choice))))
         (content (and message (cdr (assoc 'content message)))))
    (unless content
      (error "Unexpected response format: %s" 
             (json-encode json-data)))
    content))

;; ------------------------------------------------------------------
;; Provider Implementations
;; ------------------------------------------------------------------

;; Default providers will be defined in separate files
;; chat-llm-kimi.el, chat-llm-openai.el, etc.

(provide 'chat-llm)
;;; chat-llm.el ends here
