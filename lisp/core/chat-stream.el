;;; chat-stream.el --- Streaming response handling -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

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
(require 'chat-log)
(require 'chat-request-diagnostics)

;; ------------------------------------------------------------------
;; Variables
;; ------------------------------------------------------------------

(defvar-local chat-stream--partial-line ""
  "Incomplete SSE line carried between process filter calls.")

(defvar chat-stream--curl nil
  "Cached location of the curl executable, or nil when not yet looked up.")

(defun chat-stream--ensure-curl ()
  "Signal unless curl can be found, remembering where it was.
`executable-find' walks `exec-path' and stats each entry, which costs
real milliseconds on a long path -- and it was paying that on every
request to answer a question whose answer does not change."
  (or chat-stream--curl
      (setq chat-stream--curl (executable-find "curl"))
      (error "curl executable not found in PATH")))

(defun chat-stream--redact-curl-args-for-log (args)
  "Return ARGS with sensitive values redacted for logging."
  (let ((result nil))
    (while args
      (let ((arg (car args)))
        (cond
         ((string-prefix-p "Authorization: Bearer " arg)
          (push "Authorization: Bearer <redacted>" result))
         ((and (string= arg "-d") (cdr args))
          (push arg result)
          (push (format "<%d bytes>" (string-bytes (cadr args))) result)
          (setq args (cdr args)))
         (t
          (push arg result))))
      (setq args (cdr args)))
    (nreverse result)))

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
             (json-key-type 'symbol)
             (data (json-read-from-string json-string))
             (config (chat-llm-get-provider provider))
             (parser (or (plist-get config :stream-fn)
                         #'chat-stream--extract-openai-content)))
        (funcall parser data))
    (error nil)))

(defun chat-stream--extract-openai-content (data)
  "Extract stream content from OpenAI-compatible DATA."
  (let* ((choices (or (cdr (assoc 'choices data))
                      (cdr (assoc "choices" data))))
         (first-choice (car-safe choices))
         (delta (and (listp first-choice)
                     (or (cdr (assoc 'delta first-choice))
                         (cdr (assoc "delta" first-choice)))))
         (content (and (listp delta)
                       (or (cdr (assoc 'content delta))
                           (cdr (assoc "content" delta))))))
    (and (stringp content) content)))

(defun chat-stream--alist-get (alist key)
  "Return KEY from ALIST, accepting symbol or string keys."
  (or (cdr (assq key alist))
      (cdr (assoc key alist))
      (cdr (assoc (symbol-name key) alist))))

(defun chat-stream--ensure-call-acc (acc index)
  "Grow ACC so INDEX is a valid slot."
  (let ((vec (or acc (vector))))
    (while (<= (length vec) index)
      (setq vec (vconcat vec (vector (list :id nil :name nil :arguments "")))))
    vec))

(defun chat-stream--merge-tool-call-delta (acc call)
  "Merge one streamed CALL into ACC and return the new vector."
  (let* ((index (or (chat-stream--alist-get call 'index) 0))
         (function (chat-stream--alist-get call 'function))
         (id (chat-stream--alist-get call 'id))
         (name (or (and (listp function) (chat-stream--alist-get function 'name))
                   (chat-stream--alist-get call 'name)))
         (arguments (or (and (listp function)
                             (chat-stream--alist-get function 'arguments))
                        (chat-stream--alist-get call 'arguments)
                        ""))
         (vec (chat-stream--ensure-call-acc acc index))
         (current (aref vec index)))
    (when (and (stringp id) (not (string-empty-p id)))
      (setq current (plist-put current :id id)))
    (when (and (stringp name) (not (string-empty-p name)))
      (setq current (plist-put current :name name)))
    (when (stringp arguments)
      (setq current (plist-put current :arguments
                               (concat (or (plist-get current :arguments) "")
                                       arguments))))
    (aset vec index current)
    vec))

(defun chat-stream--normalize-finish-reason (reason)
  "Normalize provider REASON to the agent finish contract."
  (pcase reason
    ((or "max_tokens" "length") "length")
    ("tool_use" "tool_calls")
    (_ reason)))

(defun chat-stream--anthropic-tool-start (data)
  "Return an OpenAI-shaped tool delta for Anthropic start DATA."
  (let* ((index (or (chat-stream--alist-get data 'index) 0))
         (block (chat-stream--alist-get data 'content_block)))
    (when (and (listp block)
               (equal (chat-stream--alist-get block 'type) "tool_use"))
      `((index . ,index)
        (id . ,(chat-stream--alist-get block 'id))
        (name . ,(chat-stream--alist-get block 'name))
        (arguments . ,(let ((input (chat-stream--alist-get block 'input)))
                        (if (or (null input)
                                (and (hash-table-p input)
                                     (zerop (hash-table-count input))))
                            ""
                          (json-encode input))))))))

(defun chat-stream--anthropic-tool-delta (data)
  "Return an OpenAI-shaped tool delta for Anthropic delta DATA."
  (let ((delta (chat-stream--alist-get data 'delta)))
    (when (and (listp delta)
               (equal (chat-stream--alist-get delta 'type)
                      "input_json_delta"))
      `((index . ,(or (chat-stream--alist-get data 'index) 0))
        (arguments . ,(or (chat-stream--alist-get delta 'partial_json)
                          ""))))))

(defun chat-stream--extract-reasoning-data (data)
  "Return a reasoning text delta from decoded stream DATA."
  (let* ((choices (chat-stream--alist-get data 'choices))
         (first (car-safe choices))
         (openai-delta (and (listp first)
                            (chat-stream--alist-get first 'delta)))
         (delta (or openai-delta (chat-stream--alist-get data 'delta))))
    (when (listp delta)
      (let ((text (or (chat-stream--alist-get delta 'reasoning_content)
                      (chat-stream--alist-get delta 'reasoning)
                      (chat-stream--alist-get delta 'thinking))))
        (and (stringp text) text)))))

(defun chat-stream-accumulate-payload (proc json-string)
  "Accumulate native stream metadata from JSON-STRING onto PROC."
  (when (and proc (stringp json-string) (not (string-empty-p json-string)))
    (condition-case nil
        (let* ((json-object-type 'alist)
               (json-array-type 'list)
               (json-key-type 'symbol)
               (data (json-read-from-string json-string))
               (choices (chat-stream--alist-get data 'choices))
               (first (car-safe choices))
               (delta (and (listp first) (chat-stream--alist-get first 'delta)))
               (message-delta (chat-stream--alist-get data 'delta))
               (reason
                (or (and (listp first)
                         (chat-stream--alist-get first 'finish_reason))
                    (and (listp message-delta)
                         (chat-stream--alist-get message-delta 'stop_reason))
                    (chat-stream--alist-get data 'stop_reason)))
               (calls
                (or (and (listp delta)
                         (chat-stream--alist-get delta 'tool_calls))
                    (and (listp first)
                         (let ((message (chat-stream--alist-get first 'message)))
                           (and (listp message)
                                (chat-stream--alist-get message 'tool_calls))))
                    (when-let ((start (chat-stream--anthropic-tool-start data)))
                      (list start))
                    (when-let ((tool-delta
                                (chat-stream--anthropic-tool-delta data)))
                      (list tool-delta))))
               (reasoning (chat-stream--extract-reasoning-data data))
               (event-type (chat-stream--alist-get data 'type)))
          (when (and (stringp reason) (not (string-empty-p reason)))
            (process-put proc 'chat-stream-finish-reason
                         (chat-stream--normalize-finish-reason reason)))
          (when (and (stringp reasoning) (not (string-empty-p reasoning)))
            ;; Pushed rather than concatenated: this is read once, when the
            ;; stream ends, and rebuilding all of it per delta made a long
            ;; reasoning trace quadratic to collect.
            (process-put proc 'chat-stream-reasoning-parts
                         (cons reasoning
                               (process-get proc
                                            'chat-stream-reasoning-parts))))
          (when (equal event-type "error")
            (let ((error-data (chat-stream--alist-get data 'error)))
              (process-put proc 'chat-stream-http-error
                           (or (and (listp error-data)
                                    (chat-stream--alist-get error-data 'message))
                               "Provider stream error"))))
          (dolist (call (if (listp calls) calls nil))
            (when (listp call)
              (process-put proc 'chat-stream-tool-calls-acc
                           (chat-stream--merge-tool-call-delta
                            (process-get proc 'chat-stream-tool-calls-acc)
                            call)))))
      (error nil))))

(defun chat-stream--parse-arguments (raw)
  "Parse streamed tool ARGUMENTS JSON into an alist."
  (cond
   ((and (stringp raw) (not (string-empty-p raw)))
    (condition-case nil
        (let ((json-object-type 'alist)
              (json-array-type 'list)
              (json-key-type 'string))
          (json-read-from-string raw))
      (error nil)))
   ((listp raw) raw)
   (t nil)))

(defun chat-stream--reasoning-text (proc)
  "Return the reasoning PROC accumulated, in arrival order."
  (when-let ((parts (and proc (process-get proc
                                           'chat-stream-reasoning-parts))))
    (apply #'concat (reverse parts))))

(defun chat-stream-native-result (proc)
  "Return accumulated native tool-calls and finish-reason from PROC."
  (let* ((acc (and proc (process-get proc 'chat-stream-tool-calls-acc)))
         (reason (and proc (process-get proc 'chat-stream-finish-reason)))
         (reasoning (chat-stream--reasoning-text proc))
         (calls nil))
    (when acc
      (dotimes (index (length acc))
        (let* ((item (aref acc index))
               (name (plist-get item :name))
               (raw (plist-get item :arguments)))
          (when (and (stringp name) (not (string-empty-p name)))
            (push (list :id (or (plist-get item :id)
                                (format "call-%d" (1+ index)))
                        :name name
                        :arguments (or (chat-stream--parse-arguments raw) nil))
                  calls)))))
    (append (when calls (list :tool-calls (nreverse calls)))
            (when reason (list :finish-reason reason))
            (when reasoning (list :reasoning reasoning)))))

;; ------------------------------------------------------------------
;; Buffer Insertion
;; ------------------------------------------------------------------

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
         (url (chat-llm--request-url provider options))
         (headers (chat-llm--make-headers provider))
         (request-id (plist-get options :request-id))
         (reasoning-callback (plist-get options :on-reasoning))
         (payload-callback (plist-get options :on-payload))
         ;; Build request body
         (opts (plist-put (copy-tree options) :stream t))
         (_ (chat-log-timing-mark "headers"))
         (body (chat-llm--build-request provider messages opts))
         (_ (chat-log-timing-mark "build"))
         ;; Encode body for curl (handle multibyte characters)
         (body-str (json-encode body))
         (body-encoded (if (multibyte-string-p body-str)
                           (encode-coding-string body-str 'utf-8)
                         body-str))
         (_ (chat-log-timing-mark "encode"))
         (curl (chat-stream--ensure-curl))
         (curl-config (chat-llm--curl-post-config url headers t nil))
         (curl-config-file (chat-llm--make-curl-config-file curl-config))
         (curl-command (list curl "--config" curl-config-file
                             "--data-binary" "@-"))
         ;; Buffer for accumulating partial lines
         (buffer (generate-new-buffer " *chat-stream*"))
         (content-buffer "")
         (process nil))
    
    ;; Set up buffer-local variables
    (with-current-buffer buffer
      (setq-local chat-stream--partial-line ""))
    
    ;; Log request metadata without leaking user content or secrets.  One
    ;; line rather than four: each `chat-log' call opens the file, appends
    ;; and closes it, and this happens while the reader is waiting.
    (chat-log "[REQUEST] %s | %d bytes | %d messages | transport private-config+stdin-body"
              url
              (string-bytes body-encoded)
              (length messages))
    (chat-log-timing-mark "log")
    (condition-case err
        (progn
          (setq process (make-process
                         :name "chat-stream"
                         :buffer buffer
                         :command curl-command
                         :coding 'binary
                         :connection-type 'pipe
                         :filter (lambda (proc string)
                                  (chat-stream--handle-output
                                   proc string provider callback reasoning-callback
                                   payload-callback))
                         :sentinel (lambda (proc event)
                                    (chat-log "[STREAM] Process event: %s" event)
                                    (when (memq (process-status proc) '(exit signal))
                                      (chat-llm--cleanup-curl-config proc)
                                      (when (buffer-live-p (process-buffer proc))
                                        ;; HTTP error bodies and final SSE chunks
                                        ;; may lack a final newline.
                                        (when (eq (process-status proc) 'exit)
                                          (with-current-buffer (process-buffer proc)
                                            (when (and (stringp chat-stream--partial-line)
                                                       (not (string-empty-p chat-stream--partial-line)))
                                              (chat-stream--handle-output
                                               proc
                                               (concat chat-stream--partial-line "\n")
                                               provider
                                               callback
                                               reasoning-callback
                                               payload-callback))))
                                        (kill-buffer (process-buffer proc)))))
                         :stderr (get-buffer-create "*chat-stream-err*")))
          (process-put process 'chat-curl-config-file curl-config-file)
          (chat-llm--send-curl-body process body-encoded))
      (error
       (when (and process (process-live-p process))
         (delete-process process))
       (chat-llm--delete-curl-config-file curl-config-file)
       (when request-id
         (chat-request-diagnostics-record
          request-id
          'error
          :error (error-message-string err)
          :summary "Failed to start stream"))
       (chat-log "[STREAM] make-process FAILED: %s" (error-message-string err))
       (kill-buffer buffer)
       (signal (car err) (cdr err))))
    ;; Forking is the one cost on this path that cannot be measured
    ;; anywhere but the reader's own Emacs: it scales with the heap the
    ;; parent has accumulated, and a batch process has almost none.
    (chat-log-timing-mark "spawn")
    (when request-id
      (process-put process 'chat-request-id request-id)
      (chat-request-diagnostics-record
       request-id
       'stream-started
       :process process
       :transport 'stream
       :summary (format "Started streaming request to %s" provider)))
    (chat-log "[STREAM] Process started: %S" process)
    (chat-log-timing-mark "diagnostics")
    process))

(defun chat-stream--handle-output
    (proc string provider callback
          &optional reasoning-callback payload-callback)
  "Handle output STRING from process PROC."
  (chat-log "[STREAM] Received %d bytes" (length string))
  (condition-case err
      (let ((decoded-str (decode-coding-string string 'utf-8)))
        (with-current-buffer (process-buffer proc)
          (let* ((combined (concat (or chat-stream--partial-line "") decoded-str))
                 (complete-lines (split-string combined "\n"))
                 (has-trailing-newline (string-suffix-p "\n" combined))
                 (request-id (process-get proc 'chat-request-id)))
            (setq chat-stream--partial-line
                  (if has-trailing-newline
                      ""
                    (car (last complete-lines))))
            (unless has-trailing-newline
              (setq complete-lines (butlast complete-lines)))
            (dolist (line complete-lines)
              (let ((clean-line (string-trim-right line "\r")))
                (if (chat-stream--parse-sse-line clean-line)
                    (let ((data (chat-stream--parse-sse-line clean-line)))
                      (chat-stream-accumulate-payload proc data)
                      (when payload-callback
                        (condition-case callback-error
                            (funcall payload-callback data)
                          (error
                           (chat-log
                            "[STREAM] Payload callback error: %s"
                            (error-message-string callback-error)))))
                      (when reasoning-callback
                        (let* ((json-object-type 'alist)
                               (json-array-type 'list)
                               (decoded (condition-case nil
                                            (json-read-from-string data)
                                          (error nil)))
                               (reasoning
                                (and decoded
                                     (chat-stream--extract-reasoning-data
                                      decoded))))
                          (when (and (stringp reasoning)
                                     (not (string-empty-p reasoning)))
                            ;; Recorded nowhere before, so a model thinking
                            ;; for a minute registered as a request that had
                            ;; produced nothing at all.
                            (when request-id
                              (chat-request-diagnostics-record
                               request-id
                               'stream-reasoning
                               :process proc
                               :chars (length reasoning)
                               :summary "Receiving reasoning"))
                            (condition-case callback-error
                                (funcall reasoning-callback reasoning)
                              (error
                               (chat-log
                                "[STREAM] Reasoning callback error: %s"
                                (error-message-string callback-error)))))))
                      (let ((content (chat-stream--extract-content data provider)))
                        (when (and (stringp content) (not (string-empty-p content)))
                          (when-let* ((trace
                                       (and request-id
                                            (chat-request-diagnostics-get
                                             request-id))))
                            (chat-request-diagnostics-record
                             request-id
                             'stream-chunk
                             :process proc
                             :summary (format "Received %d streamed chunks"
                                              (1+ (or (chat-request-trace-stream-chunk-count
                                                       trace)
                                                      0)))))
                          (condition-case callback-error
                              (funcall callback content)
                            (error
                             (chat-log "[STREAM] Callback error: %s"
                                       (error-message-string callback-error)))))))
                  ;; Not an SSE data line: an HTTP error body arrives as a
                  ;; plain JSON object, so capture its message for the
                  ;; sentinel to surface.
                  (when (string-prefix-p "{\"error\"" (string-trim-left clean-line))
                    (let ((message-text
                           (condition-case nil
                               (cdr (assoc 'message
                                           (cdr (assoc 'error
                                                       (json-read-from-string clean-line)))))
                             (error nil))))
                      (process-put proc 'chat-stream-http-error
                                   (or message-text clean-line))))))))))
    (error
     (when-let ((request-id (process-get proc 'chat-request-id)))
       (chat-request-diagnostics-record
        request-id
        'error
        :process proc
        :error (error-message-string err)
        :summary "Failed to process stream output"))
     (chat-log "[STREAM] Error in handle-output: %s" (error-message-string err)))))

(provide 'chat-stream)
;;; chat-stream.el ends here
