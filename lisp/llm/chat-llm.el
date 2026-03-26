;;; chat-llm.el --- LLM API abstraction layer -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

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
(require 'subr-x)
(require 'chat-log)

(defvar-local chat-llm--timeout-timer nil
  "Timeout timer for the current async request buffer.")

(defvar-local chat-llm--callback-finished nil
  "Whether the async request buffer has already completed.")

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

(defun chat-llm-provider-option (symbol key)
  "Get provider config KEY for SYMBOL."
  (plist-get (chat-llm-get-provider symbol) key))

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
  "Convert chat MESSAGE structs to API format.
Filters out empty assistant messages which are not allowed by the API."
  (vconcat
   (delq nil
         (mapcar (lambda (msg)
                   (let ((role (chat-message-role msg))
                         (content (chat-message-content msg)))
                     ;; Skip empty assistant messages
                     (when (or (not (eq role :assistant))
                               (and content (not (string-blank-p content))))
                       `((role . ,(if (keywordp role)
                                     (substring (symbol-name role) 1)
                                   (symbol-name role)))
                         (content . ,(or content ""))))))
                 messages))))

(defun chat-llm--request-builder (config)
  "Return the request builder function from CONFIG."
  (or (plist-get config :build-request-fn)
      (plist-get config :request-fn)))

(defun chat-llm--response-parser (config)
  "Return the response parser function from CONFIG."
  (or (plist-get config :response-fn)
      #'chat-llm--default-parse-response))

(defun chat-llm--build-request (provider messages options)
  "Build request payload for PROVIDER with MESSAGES and OPTIONS."
  (let* ((config (chat-llm-get-provider provider))
         (builder (chat-llm--request-builder config))
         (model (or (plist-get options :model)
                    (plist-get config :model)))
         (temperature (or (plist-get options :temperature) 0.7))
         (max-tokens (plist-get options :max-tokens))
         (stream (plist-get options :stream))
         (formatted-msgs (chat-llm--format-messages messages)))
    (chat-log "[BUILD-REQUEST] Provider: %s, Model: %s" provider model)
    (chat-log "[BUILD-REQUEST] Formatted messages: %S" formatted-msgs)
    (if builder
        (funcall builder messages options)
      (list :model model
            :messages formatted-msgs
            :temperature temperature
            :stream stream
            :max_tokens max-tokens))))

(defun chat-llm--request-url (config)
  "Return the request URL for CONFIG."
  (concat (plist-get config :base-url) "/chat/completions"))

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
        ;; Ensure body is unibyte for HTTP request (fix multibyte text error)
        (url-request-data (if (multibyte-string-p body)
                              (encode-coding-string body 'utf-8)
                            body))
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
                  ;; Extract body and decode UTF-8
                  (if (re-search-forward "\n\n" nil t)
                      (let ((raw-body (buffer-substring (point) (point-max))))
                        ;; Decode UTF-8 response to handle Chinese characters
                        (setq response-body (decode-coding-string raw-body 'utf-8)))
                    (setq response-body ""))
                  (chat-log "[LLM] Response body length: %d bytes" (length response-body))
                  (cons response-body status-code))
              (kill-buffer response-buffer))))
      (error
       (when response-buffer (kill-buffer response-buffer))
       (signal (car err) (cdr err))))))

(defun chat-llm--parse-http-response-buffer ()
  "Parse the current HTTP response buffer.
Returns a cons cell of raw response body and status code."
  (goto-char (point-min))
  (let (status-code response-body)
    (when (looking-at "HTTP/[^ ]+ \\([0-9]+\\)")
      (setq status-code (string-to-number (match-string 1)))
      (chat-log "[LLM] HTTP status code: %d" status-code))
    (if (re-search-forward "\r?\n\r?\n" nil t)
        (let ((raw-body (buffer-substring (point) (point-max))))
          (setq response-body (decode-coding-string raw-body 'utf-8)))
      (setq response-body ""))
    (chat-log "[LLM] Response body length: %d bytes" (length response-body))
    (cons response-body status-code)))

(defun chat-llm--header-value (headers name)
  "Return header NAME from HEADERS."
  (cdr (assoc name headers)))

(defun chat-llm--post-async (url headers body success error &optional timeout-secs)
  "Make asynchronous POST request to URL.
SUCCESS receives RAW-BODY and STATUS-CODE.
ERROR receives a string message."
  (chat-log "[LLM] Async POST to %s" url)
  (let ((url-request-method "POST")
        (url-request-extra-headers headers)
        (url-request-data (if (multibyte-string-p body)
                              (encode-coding-string body 'utf-8)
                            body))
        (url-user-agent (or (cdr (assoc "User-Agent" headers))
                            "chat.el/1.0")))
    (let ((request-buffer
           (url-retrieve
            url
            (lambda (status success-callback error-callback)
              (let ((response-buffer (current-buffer)))
                (unwind-protect
                    (unless chat-llm--callback-finished
                      (setq chat-llm--callback-finished t)
                      (when chat-llm--timeout-timer
                        (cancel-timer chat-llm--timeout-timer)
                        (setq chat-llm--timeout-timer nil))
                      (condition-case err
                          (if-let ((request-error (plist-get status :error)))
                              (funcall error-callback (format "%s" request-error))
                            (let* ((parsed (chat-llm--parse-http-response-buffer))
                                   (raw-body (car parsed))
                                   (status-code (cdr parsed)))
                              (funcall success-callback raw-body status-code)))
                        (error
                         (funcall error-callback (error-message-string err)))))
                  (when (buffer-live-p response-buffer)
                    (kill-buffer response-buffer)))))
            (list success error)
            t
            t)))
      (when (buffer-live-p request-buffer)
        (with-current-buffer request-buffer
          (setq-local chat-llm--callback-finished nil)
          (when timeout-secs
            (setq-local
             chat-llm--timeout-timer
             (run-at-time
              timeout-secs nil
              (lambda (buffer error-callback timeout-value)
                (when (buffer-live-p buffer)
                  (with-current-buffer buffer
                    (unless chat-llm--callback-finished
                      (setq chat-llm--callback-finished t)
                      (let ((proc (get-buffer-process buffer)))
                        (when (process-live-p proc)
                          (delete-process proc)))
                      (funcall error-callback
                               (format "Request timeout after %d seconds" timeout-value))
                      (kill-buffer buffer)))))
              request-buffer
              error
              timeout-secs))))
      request-buffer))))

(defun chat-llm--post-async-curl (url headers body success error &optional timeout-secs)
  "Make asynchronous POST request to URL with curl.
SUCCESS receives RAW-BODY and STATUS-CODE.
ERROR receives a string message."
  (let* ((request-buffer (generate-new-buffer " *chat-llm-curl*"))
         (user-agent (chat-llm--header-value headers "User-Agent"))
         (curl-args
          (append
           (list "-s" "-S" "-i"
                 "-X" "POST"
                 "-H" (format "Content-Type: %s"
                              (or (chat-llm--header-value headers "Content-Type")
                                  "application/json"))
                 "-H" (format "Authorization: %s"
                              (or (chat-llm--header-value headers "Authorization")
                                  ""))
                 "--data-binary" body)
           (when-let ((accept (chat-llm--header-value headers "Accept")))
             (list "-H" (format "Accept: %s" accept)))
           (when user-agent
             (list "-A" user-agent))
           (list url)))
         (sentinel
          (lambda (proc event)
            (when (memq (process-status proc) '(exit signal))
              (let ((response-buffer (process-buffer proc)))
                (when (buffer-live-p response-buffer)
                  (with-current-buffer response-buffer
                    (unless chat-llm--callback-finished
                      (setq chat-llm--callback-finished t)
                      (when chat-llm--timeout-timer
                        (cancel-timer chat-llm--timeout-timer)
                        (setq chat-llm--timeout-timer nil))
                      (condition-case parse-error
                          (let* ((parsed (chat-llm--parse-http-response-buffer))
                                 (raw-body (car parsed))
                                 (status-code (cdr parsed)))
                            (if status-code
                                (funcall success raw-body status-code)
                              (funcall error
                                       (format "curl request failed: %s"
                                               (string-trim event)))))
                        (error
                         (funcall error
                                  (if (> (process-exit-status proc) 0)
                                      (format "curl request failed: %s"
                                              (string-trim event))
                                    (error-message-string parse-error))))))
                    (kill-buffer response-buffer))))))))
    (with-current-buffer request-buffer
      (setq-local chat-llm--callback-finished nil)
      (when timeout-secs
        (setq-local
         chat-llm--timeout-timer
         (run-at-time
          timeout-secs nil
          (lambda (buffer error-callback timeout-value)
            (when (buffer-live-p buffer)
              (with-current-buffer buffer
                (unless chat-llm--callback-finished
                  (setq chat-llm--callback-finished t)
                  (let ((proc (get-buffer-process buffer)))
                    (when (process-live-p proc)
                      (delete-process proc)))
                  (funcall error-callback
                           (format "Request timeout after %d seconds" timeout-value))
                  (kill-buffer buffer)))))
          request-buffer
          error
          timeout-secs))))
    (condition-case err
        (progn
          (make-process
           :name "chat-llm-curl"
           :buffer request-buffer
           :command (cons "curl" curl-args)
           :noquery t
           :sentinel sentinel)
          request-buffer)
      (error
       (when (buffer-live-p request-buffer)
         (kill-buffer request-buffer))
       (signal (car err) (cdr err))))))

(defun chat-llm--post-async-dispatch (config url headers body success error timeout-secs)
  "Send one async request using CONFIG specific transport."
  (pcase (plist-get config :async-transport)
    ('curl
     (chat-llm--post-async-curl url headers body success error timeout-secs))
    (_
     (chat-llm--post-async url headers body success error timeout-secs))))

(defun chat-llm--decode-response (config raw-request raw-response status-code)
  "Decode one response using CONFIG and request metadata."
  (let ((parser (chat-llm--response-parser config)))
    (if (/= status-code 200)
        (error "HTTP error %d: %s" status-code raw-response)
      (let ((json-data (json-read-from-string raw-response)))
        (list :content (funcall parser json-data)
              :raw-request raw-request
              :raw-response raw-response)))))

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
         (request-body (chat-llm--build-request provider messages options))
         (headers (chat-llm--make-headers provider))
         (timeout (or (plist-get options :timeout) 60))
         (raw-request (json-encode request-body)))
    (chat-log "[LLM] Base URL: %s" (plist-get config :base-url))
    (chat-log "[LLM] Request body: %s" raw-request)
    (chat-log "[LLM] Headers present: %s" (if headers "yes" "no"))
    (let* ((result (chat-llm--post-sync
                    (chat-llm--request-url config)
                    headers
                    raw-request
                    timeout))
           (raw-response (car result))
           (status-code (cdr result)))
      (chat-log "[LLM] Got response body: %s..." (substring raw-response 0 (min 100 (length raw-response))))
      (chat-llm--decode-response config raw-request raw-response status-code))))

(defun chat-llm-request-async (provider messages success-callback error-callback &optional options)
  "Send an asynchronous request to PROVIDER with MESSAGES.
SUCCESS-CALLBACK receives the response plist.
ERROR-CALLBACK receives an error string.
Returns a request handle."
  (chat-log "[LLM] Starting async request to provider: %s" provider)
  (let* ((config (chat-llm-get-provider provider))
         (request-body (chat-llm--build-request provider messages options))
         (headers (chat-llm--make-headers provider))
         (timeout (or (plist-get options :timeout) 60))
         (raw-request (json-encode request-body)))
    (chat-log "[LLM] Async request body: %s" raw-request)
    (chat-llm--post-async-dispatch
     config
     (chat-llm--request-url config)
     headers
     raw-request
     (lambda (raw-response status-code)
       (condition-case err
           (funcall success-callback
                    (chat-llm--decode-response config raw-request raw-response status-code))
         (error
          (funcall error-callback (error-message-string err)))))
     (lambda (err)
       (funcall error-callback
                (if (stringp err)
                    err
                  (error-message-string err))))
     timeout)))

(defun chat-llm-cancel-request (handle)
  "Cancel asynchronous request HANDLE."
  (when (buffer-live-p handle)
    (with-current-buffer handle
      (when chat-llm--timeout-timer
        (cancel-timer chat-llm--timeout-timer)
        (setq chat-llm--timeout-timer nil))
      (setq chat-llm--callback-finished t))
    (let ((proc (get-buffer-process handle)))
      (when (process-live-p proc)
        (delete-process proc)))
    (kill-buffer handle)
    t))

(defun chat-llm-stream (provider messages callback &optional options)
  "Stream response from PROVIDER with MESSAGES to CALLBACK.

CALLBACK is called with each chunk of the response.
OPTIONS is an optional plist of request parameters."
  (chat-llm-request-async
   provider
   messages
   (lambda (result)
     (funcall callback (plist-get result :content))
     (funcall callback nil))
   (lambda (err)
     (funcall callback nil)
     (error "%s" err))
   (plist-put (copy-tree options) :stream t)))

(defun chat-llm--default-parse-response (json-data)
  "Default response parser for JSON-DATA."
  ;; Check for API error response
  (when-let ((error-obj (cdr (assoc 'error json-data))))
    (let ((err-msg (cdr (assoc 'message error-obj)))
          (err-type (cdr (assoc 'type error-obj))))
      (error "API error: %s (%s)" (or err-msg "Unknown") (or err-type "unknown"))))
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

;; ------------------------------------------------------------------
;; Provider Implementations
;; ------------------------------------------------------------------

;; Default providers will be defined in separate files
;; chat-llm-kimi.el, chat-llm-openai.el, etc.

(provide 'chat-llm)
;;; chat-llm.el ends here
