;;; chat-stream.el --- Streaming response handling -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: stream, sse, realtime

;; This file is not part of GNU Emacs.

;;; Commentary:

;; This module handles streaming (SSE) responses from LLM APIs.
;; It provides real-time display of AI responses character by character.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)

;; ------------------------------------------------------------------
;; Variables
;; ------------------------------------------------------------------

(defvar chat-stream--buffer nil
  "Buffer for accumulating streamed content.")

(defvar chat-stream--insert-marker nil
  "Marker where next content should be inserted.")

(defvar chat-stream--content-callback nil
  "Callback function for new content chunks.")

(defvar chat-stream--done-callback nil
  "Callback function when stream is complete.")

;; ------------------------------------------------------------------
;; SSE Parsing
;; ------------------------------------------------------------------

(defun chat-stream--parse-sse-line (line)
  "Parse a single SSE LINE.

Returns the data payload if this is a data line, nil otherwise.
Handles format: data: {...} or data:{...} (with or without space)"
  (cond
   ;; Standard format: "data: {...}"
   ((string-prefix-p "data: " line)
    (let ((data (substring line 6)))
      (unless (string= data "[DONE]")
        data)))
   ;; Non-standard format: "data:{...}" (no space)
   ((string-prefix-p "data:" line)
    (let ((data (substring line 5)))
      (unless (string= data "[DONE]")
        data)))))

(defun chat-stream--extract-content (json-string provider)
  "Extract content from JSON-STRING based on PROVIDER format."
  (condition-case nil
      (let* ((json-object-type 'alist)
             (json-array-type 'list)
             (json-key-type 'string)
             (data (json-read-from-string json-string)))
        (pcase provider
          ((or 'kimi 'kimi-code) (chat-stream--extract-openai-content data))
          (_ (chat-stream--extract-openai-content data))))
    (error nil)))

(defun chat-stream--extract-openai-content (data)
  "Extract stream content from OpenAI-compatible DATA."
  (let* ((choices (cdr (assoc "choices" data)))
         (first-choice (car-safe choices))
         (delta (and (listp first-choice)
                     (cdr (assoc "delta" first-choice))))
         (content (and (listp delta)
                       (cdr (assoc "content" delta)))))
    content))

;; ------------------------------------------------------------------
;; Buffer Insertion
;; ------------------------------------------------------------------

(defun chat-stream--insert-text (text)
  "Insert TEXT at stream insertion marker."
  (when (and chat-stream--buffer
             (buffer-live-p chat-stream--buffer)
             chat-stream--insert-marker)
    (with-current-buffer chat-stream--buffer
      (let ((inhibit-read-only t))
        (save-excursion
          (goto-char chat-stream--insert-marker)
          (insert text)
          (set-marker chat-stream--insert-marker (point))))
      ;; Force display update
      (redisplay t))))

;; ------------------------------------------------------------------
;; Process Filter
;; ------------------------------------------------------------------

(defun chat-stream--process-filter (proc string)
  "Process filter for stream PROC receiving STRING."
  (when chat-stream--content-callback
    (funcall chat-stream--content-callback string)))

(defun chat-stream--process-sentinel (proc event)
  "Process sentinel for stream PROC with EVENT."
  (when (and (string-match-p "finished\\|closed" event)
             chat-stream--done-callback)
    (funcall chat-stream--done-callback)))

;; ------------------------------------------------------------------
;; Main Stream Function
;; ------------------------------------------------------------------

(defun chat-stream-request (provider messages callback &optional options)
  "Make streaming request to PROVIDER with MESSAGES.

CALLBACK is called with each content chunk as it arrives.
OPTIONS is an optional plist of request parameters.
Returns the process object."
  ;; Check dependencies
  (unless (fboundp 'chat-llm-get-provider)
    (error "chat-llm-get-provider not defined - check chat-llm.el is loaded"))
  (unless (fboundp 'chat-llm--build-request)
    (error "chat-llm--build-request not defined - check chat-llm.el is loaded"))
  (let* ((config (chat-llm-get-provider provider))
         (base-url (plist-get config :base-url))
         (api-key (chat-llm--get-api-key provider))
         (url (concat base-url "/chat/completions"))
         ;; Build request body
         (opts (plist-put (copy-tree options) :stream t))
         (body (chat-llm--build-request provider messages opts))
         ;; Get User-Agent from provider config
         (user-agent (let ((headers-fn (plist-get config :headers)))
                       (if (functionp headers-fn)
                           (cdr (assoc "User-Agent" (funcall headers-fn)))
                         "chat.el/1.0")))
         ;; Encode body for curl (handle multibyte characters)
         (body-str (json-encode body))
         (body-encoded (if (multibyte-string-p body-str)
                           (encode-coding-string body-str 'utf-8)
                         body-str))
         ;; Create curl command
         (curl-args (let ((base-args (list "-s" "-N"  ; Silent, no buffer
                                           "-X" "POST"
                                           "-H" "Content-Type: application/json"
                                           "-H" (format "Authorization: Bearer %s" api-key)
                                           "-d" body-encoded))
                          (ua-args (when user-agent
                                     (list "-A" user-agent))))
                      (append base-args ua-args (list url))))
         ;; Buffer for accumulating partial lines
         (buffer (generate-new-buffer " *chat-stream*"))
         (content-buffer "")
         (process nil))
    
    ;; Set up buffer-local variables
    (with-current-buffer buffer
      (setq-local chat-stream--partial-line ""))
    
    ;; Check curl is available
    (unless (executable-find "curl")
      (error "curl executable not found in PATH"))
    
    ;; Log request body for debugging
    (chat-log "[REQUEST] URL: %s" url)
    (chat-log "[REQUEST] Body: %s" (json-encode body))
    (chat-log "[REQUEST] Messages: %S" messages)
    
    ;; Start curl process
    (chat-log "[STREAM] Starting curl with args: %S" curl-args)
    (condition-case err
        (setq process (make-process
                      :name "chat-stream"
                      :buffer buffer
                      :command (cons "curl" curl-args)
                      :filter (lambda (proc string)
                               (chat-stream--handle-output proc string provider callback))
                      :sentinel (lambda (proc event)
                                 (chat-log "[STREAM] Process event: %s" event)
                                 (when (string-match-p "finished\|exited" event)
                                   (kill-buffer buffer)))
                      :stderr (get-buffer-create "*chat-stream-err*")))
      (error
       (chat-log "[STREAM] make-process FAILED: %s" (error-message-string err))
       (kill-buffer buffer)
       (signal (car err) (cdr err))))
    
    (chat-log "[STREAM] Process started: %S" process)
    process))

(defun chat-stream--handle-output (proc string provider callback)
  "Handle output STRING from process PROC."
  (chat-log "[STREAM] Received %d bytes" (length string))
  (condition-case err
      (let ((decoded-str (decode-coding-string string 'utf-8)))
        (with-current-buffer (process-buffer proc)
          (let* ((combined (concat (or chat-stream--partial-line "") decoded-str))
                 (complete-lines (split-string combined "\n"))
                 (has-trailing-newline (string-suffix-p "\n" combined)))
            (setq chat-stream--partial-line
                  (if has-trailing-newline
                      ""
                    (car (last complete-lines))))
            (unless has-trailing-newline
              (setq complete-lines (butlast complete-lines)))
            (dolist (line complete-lines)
              (let ((data (chat-stream--parse-sse-line (string-trim-right line "\r"))))
                (when data
                  (let ((content (chat-stream--extract-content data provider)))
                    (when content
                      (condition-case callback-error
                          (funcall callback content)
                        (error
                         (chat-log "[STREAM] Callback error: %s"
                                   (error-message-string callback-error))))))))))))
    (error
     (chat-log "[STREAM] Error in handle-output: %s" (error-message-string err)))))

(provide 'chat-stream)
;;; chat-stream.el ends here
