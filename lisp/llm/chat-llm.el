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
(require 'seq)
(require 'url)
(require 'subr-x)
(require 'chat-log)
(require 'chat-request-diagnostics)

(defgroup chat-llm nil
  "LLM provider abstraction for chat.el."
  :group 'chat)

(defcustom chat-llm-enabled-providers nil
  "Enabled LLM providers.
When nil, all registered providers are enabled.
When non-nil, only the listed provider symbols are available."
  :type '(choice (const :tag "Enable all registered providers" nil)
                 (repeat :tag "Enabled providers" symbol))
  :group 'chat-llm)

(defvar-local chat-llm--timeout-timer nil
  "Timeout timer for the current async request buffer.")

(defvar-local chat-llm--callback-finished nil
  "Whether the async request buffer has already completed.")

(defvar-local chat-llm--request-id nil
  "Diagnostics request id for the current async request buffer.")

;; ------------------------------------------------------------------
;; Provider Registry
;; ------------------------------------------------------------------

(defvar chat-llm-providers nil
  "Alist of registered LLM providers.
Each entry is a pair of (SYMBOL . CONFIG-PLIST).")

(defun chat-llm-get-provider-config (symbol)
  "Return raw configuration for provider SYMBOL."
  (cdr (assoc symbol chat-llm-providers)))

(defun chat-llm-provider-enabled-p (symbol)
  "Return non-nil when provider SYMBOL is enabled."
  (and (chat-llm-get-provider-config symbol)
       (or (null chat-llm-enabled-providers)
           (memq symbol chat-llm-enabled-providers))))

(defun chat-llm-enabled-providers ()
  "Return the list of enabled provider symbols."
  (mapcar #'car
          (seq-filter
           (lambda (entry)
             (chat-llm-provider-enabled-p (car entry)))
           chat-llm-providers)))

(defun chat-llm-register-provider (symbol &rest config)
  "Register a new LLM provider with SYMBOL and CONFIG.

CONFIG is a plist with keys:
  :name - Display name
  :base-url - API base URL
  :request-path - API path appended to base URL
  :request-url-fn - Function computing full request URL
  :api-key - API key string
  :api-key-fn - Function to retrieve API key
  :auth-source-host - Host name for auth-source lookup
  :auth-headers-fn - Function building authentication headers
  :model - Default model name
  :headers - Additional HTTP headers
  :request-fn - Function to build request payload
  :response-fn - Function to parse response"
  (setq chat-llm-providers
        (cons (cons symbol config)
              (assq-delete-all symbol chat-llm-providers))))

(defun chat-llm-get-provider (symbol)
  "Get configuration for provider SYMBOL."
  (when (chat-llm-provider-enabled-p symbol)
    (chat-llm-get-provider-config symbol)))

(defun chat-llm--ensure-provider (symbol)
  "Return enabled provider config for SYMBOL or signal an error."
  (or (chat-llm-get-provider symbol)
      (if (chat-llm-get-provider-config symbol)
          (error "Provider is disabled: %s" symbol)
        (error "Unknown provider: %s" symbol))))

(defun chat-llm-provider-option (symbol key)
  "Get provider config KEY for SYMBOL."
  (plist-get (chat-llm--ensure-provider symbol) key))

;; ------------------------------------------------------------------
;; API Key Management
;; ------------------------------------------------------------------

(defun chat-llm--get-api-key (provider)
  "Get API key for PROVIDER.

Checks in order:
1. api-key-fn from config
2. api-key from config
3. auth-source lookup"
  (let ((config (chat-llm--ensure-provider provider)))
    (or (when-let ((fn (plist-get config :api-key-fn)))
          (funcall fn))
        (plist-get config :api-key)
        (chat-llm--auth-source-lookup provider config))))

(defun chat-llm--auth-source-lookup (provider &optional config)
  "Look up API key for PROVIDER in auth-source using CONFIG."
  (when (require 'auth-source nil t)
    (let ((result (auth-source-search
                   :host (or (plist-get config :auth-source-host)
                             (format "%s-api" provider))
                   :user "api-key"
                   :require '(:secret)
                   :max 1)))
      (when result
        (let ((secret (plist-get (car result) :secret)))
          (if (functionp secret)
              (funcall secret)
            secret))))))

(defun chat-llm--require-api-key (provider)
  "Return API key for PROVIDER or signal a helpful error."
  (or (chat-llm--get-api-key provider)
      (error "No API key configured for provider: %s" provider)))

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
  (let* ((config (chat-llm--ensure-provider provider))
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

(defun chat-llm--request-url (provider &optional options)
  "Return the request URL for PROVIDER using OPTIONS."
  (let* ((config (chat-llm--ensure-provider provider))
         (request-url-fn (plist-get config :request-url-fn))
         (base-url (plist-get config :base-url))
         (request-path (or (plist-get config :request-path)
                           "/chat/completions")))
    (if request-url-fn
        (funcall request-url-fn provider config options)
      (concat base-url request-path))))

;; ------------------------------------------------------------------
;; HTTP Utilities
;; ------------------------------------------------------------------

(defun chat-llm--make-headers (provider)
  "Generate HTTP headers for PROVIDER."
  (let* ((config (chat-llm--ensure-provider provider))
         (extra-headers-raw (plist-get config :headers))
         (extra-headers (if (functionp extra-headers-raw)
                            (funcall extra-headers-raw)
                          extra-headers-raw))
         (auth-headers-fn (plist-get config :auth-headers-fn))
         (api-key (unless auth-headers-fn
                    (chat-llm--require-api-key provider)))
         (auth-headers
          (if auth-headers-fn
              (funcall auth-headers-fn
                       (chat-llm--require-api-key provider)
                       provider
                       config)
            (when api-key
              (list (cons "Authorization"
                          (format "Bearer %s" api-key)))))))
    (append
     (list (cons "Content-Type" "application/json"))
     auth-headers
     extra-headers)))

(defun chat-llm--curl-args-for-headers (headers)
  "Build curl `-H` arguments for HEADERS."
  (apply #'append
         (mapcar (lambda (header)
                   (list "-H" (format "%s: %s" (car header) (cdr header))))
                 headers)))

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
                 "-X" "POST")
           (chat-llm--curl-args-for-headers
            (if user-agent
                (assoc-delete-all "User-Agent" headers)
              headers))
           (list "--data-binary" body)
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
    (if (not (and (integerp status-code)
                  (>= status-code 200)
                  (< status-code 300)))
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
  (let* ((config (chat-llm--ensure-provider provider))
         (request-body (chat-llm--build-request provider messages options))
         (headers (chat-llm--make-headers provider))
         (timeout (or (plist-get options :timeout) 60))
         (raw-request (json-encode request-body)))
    (chat-log "[LLM] Base URL: %s" (plist-get config :base-url))
    (chat-log "[LLM] Request body: %s" raw-request)
    (chat-log "[LLM] Headers present: %s" (if headers "yes" "no"))
    (let* ((result (chat-llm--post-sync
                    (chat-llm--request-url provider options)
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
  (let* ((config (chat-llm--ensure-provider provider))
         (request-body (chat-llm--build-request provider messages options))
         (headers (chat-llm--make-headers provider))
         (timeout (or (plist-get options :timeout) 60))
         (raw-request (json-encode request-body))
         (request-id (plist-get options :request-id))
         (url (chat-llm--request-url provider options))
         handle)
    (chat-log "[LLM] Async request body: %s" raw-request)
    (when request-id
      (chat-request-diagnostics-record
       request-id
       'request-dispatched
       :transport (or (plist-get config :async-transport) 'url)
       :timeout timeout
       :summary (format "Dispatching request to %s" provider)))
    (when request-id
      (chat-request-diagnostics-record
       request-id
       'timeout-armed
       :timeout timeout
       :summary (format "Timeout armed for %s seconds" timeout)))
    (setq handle
          (chat-llm--post-async-dispatch
           config
           url
           headers
           raw-request
           (lambda (raw-response status-code)
             (when request-id
               (chat-request-diagnostics-record
                request-id
                'response-received
                :handle handle
                :summary (format "Received HTTP %s" status-code)))
             (condition-case err
                 (funcall success-callback
                          (chat-llm--decode-response config raw-request raw-response status-code))
               (error
                (when request-id
                  (chat-request-diagnostics-record
                   request-id
                   'error
                   :handle handle
                   :error (error-message-string err)
                   :summary "Failed to decode response"))
                (funcall error-callback (error-message-string err)))))
           (lambda (err)
             (let ((message (if (stringp err)
                                err
                              (error-message-string err))))
               (when request-id
                 (chat-request-diagnostics-record
                  request-id
                  'error
                  :handle handle
                  :error message
                  :summary "Request failed"))
               (funcall error-callback message)))
           timeout))
    (when (and request-id
               (buffer-live-p handle))
      (with-current-buffer handle
        (setq-local chat-llm--request-id request-id))
      (chat-request-diagnostics-record
       request-id
       'request-dispatched
       :handle handle
       :phase (and (chat-request-diagnostics-get request-id)
                   (chat-request-trace-phase
                    (chat-request-diagnostics-get request-id)))
       :summary "Request handle attached"))
    handle))

(defun chat-llm-cancel-request (handle)
  "Cancel asynchronous request HANDLE."
  (when (buffer-live-p handle)
    (let (request-id)
      (with-current-buffer handle
        (setq request-id chat-llm--request-id))
      (when request-id
        (chat-request-diagnostics-record
         request-id
         'cancelled
         :handle handle
         :summary "Cancelled by user")))
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

(defun chat-llm-build-openai-compatible-request (provider messages options)
  "Build an OpenAI compatible request for PROVIDER."
  (let* ((config (chat-llm--ensure-provider provider))
         (model (or (plist-get options :model)
                    (plist-get config :model)))
         (temperature (or (plist-get options :temperature) 0.7))
         (max-tokens (or (plist-get options :max-tokens)
                         (plist-get config :max-output-tokens)))
         (stream (plist-get options :stream)))
    (list :model model
          :messages (chat-llm--format-messages messages)
          :temperature temperature
          :max_tokens max-tokens
          :stream stream)))

(defun chat-llm-parse-openai-compatible-response (json-data)
  "Parse an OpenAI compatible response from JSON-DATA."
  (chat-llm--default-parse-response json-data))

(defun chat-llm-parse-openai-compatible-stream (json-data)
  "Parse an OpenAI compatible stream chunk from JSON-DATA."
  (let* ((choices (cdr (assoc 'choices json-data)))
         (first-choice (and choices
                            (if (vectorp choices)
                                (aref choices 0)
                              (car choices))))
         (delta (and first-choice (cdr (assoc 'delta first-choice)))))
    (cdr (assoc 'content delta))))

(defun chat-llm-register-openai-compatible-provider (symbol name base-url model &rest options)
  "Register SYMBOL as an OpenAI compatible provider.
NAME is the display name.
BASE-URL is the provider API base URL.
MODEL is the default remote model name.
OPTIONS are appended to the provider plist."
  (apply #'chat-llm-register-provider
         symbol
         :name name
         :base-url base-url
         :model model
         :request-fn (lambda (messages request-options)
                       (chat-llm-build-openai-compatible-request
                        symbol messages request-options))
         :response-fn #'chat-llm-parse-openai-compatible-response
         :stream-fn #'chat-llm-parse-openai-compatible-stream
         options))

;; ------------------------------------------------------------------
;; Provider Implementations
;; ------------------------------------------------------------------

;; Default providers will be defined in separate files
;; chat-llm-kimi.el, chat-llm-openai.el, etc.

(provide 'chat-llm)
;;; chat-llm.el ends here
