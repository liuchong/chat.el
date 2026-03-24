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
Handles format: data: {...}"
  (when (string-prefix-p "data: " line)
    (let ((data (substring line 6)))
      ;; Return nil for [DONE] signal
      (unless (string= data "[DONE]")
        data))))

(defun chat-stream--extract-content (json-string provider)
  "Extract content from JSON-STRING based on PROVIDER format."
  (condition-case nil
      (let* ((json-object-type 'alist)
             (json-array-type 'vector)
             (data (json-read-from-string json-string)))
        (pcase provider
          ('kimi (chat-stream--extract-kimi-content data))
          (_ (chat-stream--extract-kimi-content data))))  ; Default to Kimi format
    (error nil)))

(defun chat-stream--extract-kimi-content (data)
  "Extract content from Kimi format DATA."
  (let* ((choices (cdr (assoc 'choices data)))
         (first-choice (aref choices 0))
         (delta (cdr (assoc 'delta first-choice)))
         (content (cdr (assoc 'content delta))))
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
         ;; Create curl command
         (curl-args (let ((base-args (list "-s" "-N"  ; Silent, no buffer
                                           "-X" "POST"
                                           "-H" "Content-Type: application/json"
                                           "-H" (format "Authorization: Bearer %s" api-key)
                                           "-d" (json-encode body)))
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
    
    ;; Start curl process
    (setq process (make-process
                  :name "chat-stream"
                  :buffer buffer
                  :command (cons "curl" curl-args)
                  :filter (lambda (proc string)
                           (chat-stream--handle-output proc string provider callback))
                  :sentinel (lambda (proc event)
                             (when (string-match-p "finished" event)
                               (kill-buffer buffer)))))
    
    process))

(defun chat-stream--handle-output (proc string provider callback)
  "Handle output STRING from process PROC."
  (let ((lines (split-string string "\n")))
    (dolist (line lines)
      ;; Accumulate partial lines
      (when (> (length line) 0)
        (let ((data (chat-stream--parse-sse-line line)))
          (when data
            (let ((content (chat-stream--extract-content data provider)))
              (when content
                (funcall callback content)))))))))

(provide 'chat-stream)
;;; chat-stream.el ends here
