;;; chat-model-runtime.el --- Unified model capability and transport runtime -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; Author: chat.el contributors
;; Keywords: llm, runtime, streaming

;;; Commentary:

;; This is the one high-level request boundary.  SSE, asynchronous HTTP and
;; the compatibility streaming API all project into `chat-model-event'.
;; Low-level transports remain available to adapters, not application code.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'chat-log)
(require 'chat-llm)
(require 'chat-stream)
(require 'chat-model-capabilities)
(require 'chat-model-event)

(defun chat-model-runtime--request-id ()
  "Return a process-local model request id."
  (format "request-%x-%x" (truncate (* 1000 (float-time)))
          (random most-positive-fixnum)))

(defun chat-model-runtime--json (json-string)
  "Decode JSON-STRING into symbol-keyed alists and lists."
  (let ((json-object-type 'alist)
        (json-array-type 'list)
        (json-key-type 'symbol))
    (json-read-from-string json-string)))

(defun chat-model-runtime--tool-deltas (data)
  "Return normalized raw tool deltas from stream DATA."
  (let* ((choices (chat-stream--alist-get data 'choices))
         (first (car-safe choices))
         (delta (and (listp first) (chat-stream--alist-get first 'delta)))
         (calls
          (or (and (listp delta)
                   (chat-stream--alist-get delta 'tool_calls))
              (when-let* ((start (chat-stream--anthropic-tool-start data)))
                (list start))
              (when-let* ((part (chat-stream--anthropic-tool-delta data)))
                (list part)))))
    (mapcar
     (lambda (call)
       (let* ((fn (chat-stream--alist-get call 'function))
              (index (or (chat-stream--alist-get call 'index) 0)))
         (list :index index
               :id (chat-stream--alist-get call 'id)
               :name (or (and (listp fn)
                              (chat-stream--alist-get fn 'name))
                         (chat-stream--alist-get call 'name))
               :arguments-delta
               (or (and (listp fn)
                        (chat-stream--alist-get fn 'arguments))
                   (chat-stream--alist-get call 'arguments)))))
     (cond ((vectorp calls) (append calls nil))
           ((listp calls) calls)
           (t nil)))))

(defun chat-model-runtime--stream-error (data)
  "Return a normalized provider error payload from stream DATA."
  (let ((error-data (chat-stream--alist-get data 'error))
        (type (chat-stream--alist-get data 'type)))
    (when (or error-data (equal type "error"))
      (list :message
            (or (and (listp error-data)
                     (chat-stream--alist-get error-data 'message))
                "Provider stream error")
            :type (and (listp error-data)
                       (chat-stream--alist-get error-data 'type))
            :code (and (listp error-data)
                       (chat-stream--alist-get error-data 'code))))))

(defun chat-model-runtime--merge-usage (current update)
  "Merge partial normalized usage UPDATE into CURRENT."
  (let ((merged (copy-tree current)))
    (dolist (key '(:input-tokens :output-tokens :total-tokens
                   :cache-read-tokens :cache-write-tokens :raw))
      (when (plist-member update key)
        (setq merged (plist-put merged key (plist-get update key)))))
    (unless (plist-get merged :total-tokens)
      (when (and (numberp (plist-get merged :input-tokens))
                 (numberp (plist-get merged :output-tokens)))
        (setq merged
              (plist-put merged :total-tokens
                         (+ (plist-get merged :input-tokens)
                            (plist-get merged :output-tokens))))))
    merged))

(defun chat-model-runtime--stream-payload
    (provider json-string emit record-text record-reasoning record-usage
              record-error)
  "Normalize one stream JSON-STRING and report through callbacks."
  (condition-case err
      (let* ((data (chat-model-runtime--json json-string))
             (reasoning (chat-stream--extract-reasoning-data data))
             (text (chat-stream--extract-content json-string provider))
             (usage (chat-model-event-normalize-usage data))
             (provider-error (chat-model-runtime--stream-error data)))
        (when (and (stringp reasoning) (not (string-empty-p reasoning)))
          (funcall record-reasoning reasoning)
          (funcall emit 'reasoning-delta (list :delta reasoning)))
        (when (and (stringp text) (not (string-empty-p text)))
          (funcall record-text text)
          (funcall emit 'text-delta (list :delta text)))
        (dolist (delta (chat-model-runtime--tool-deltas data))
          (funcall emit 'tool-call-delta delta))
        (when usage
          (funcall record-usage usage)
          (funcall emit 'usage usage))
        (when provider-error
          (funcall record-error (plist-get provider-error :message))))
    (error
     (funcall record-error (error-message-string err)))))

(defun chat-model-runtime--response-events (result emit)
  "Emit normalized non-streaming delta events for RESULT."
  (when-let* ((reasoning (plist-get result :reasoning)))
    (unless (string-empty-p reasoning)
      (funcall emit 'reasoning-delta (list :delta reasoning))))
  (when-let* ((content (plist-get result :content)))
    (unless (string-empty-p content)
      (funcall emit 'text-delta (list :delta content))))
  (dolist (call (plist-get result :tool-calls))
    (funcall emit 'tool-call-delta
             (list :index nil
                   :id (plist-get call :id)
                   :name (plist-get call :name)
                   :arguments (plist-get call :arguments))))
  (when-let* ((usage (plist-get result :usage)))
    (funcall emit 'usage usage)))

(defun chat-model-request-events (provider messages callback &optional options)
  "Request PROVIDER with MESSAGES and send every normalized event to CALLBACK.

OPTIONS selects `:stream', model and provider request controls.  Known
incompatible capabilities fail before a network process or buffer is made.
Returns the low-level cancellable request handle, or nil after a preflight
failure."
  (let* ((config (chat-llm--ensure-provider provider))
         (model (or (plist-get options :model) (plist-get config :model)))
         (request-id (or (plist-get options :request-id)
                         (chat-model-runtime--request-id)))
         (sequence 0)
         (finished nil)
         (emit
          (lambda (type &optional payload)
            (unless finished
              (setq sequence (1+ sequence))
              (funcall callback
                       (chat-model-event-make
                        type provider model request-id sequence payload)))))
         (finish
          (lambda (type payload)
            (unless finished
              ;; Close first so callback re-entry cannot emit a second
              ;; terminal event for the same request.
              (setq finished t
                    sequence (1+ sequence))
              (funcall callback
                       (chat-model-event-make
                        type provider model request-id sequence payload)))))
         (finish-error
          (lambda (message)
            (funcall finish 'error (list :message message))))
         prepared)
    (condition-case err
        (setq prepared
              (chat-model-capabilities-prepare-options
               provider model (plist-put (copy-tree options)
                                         :request-id request-id)))
      (error
       (funcall finish-error (error-message-string err))))
    (when prepared
      (funcall emit 'started
               (list :stream (and (plist-get prepared :stream) t)
                     :capabilities
                     (chat-model-capabilities-resolve provider model)))
      (if (plist-get prepared :stream)
          (let ((text-parts nil)
                (reasoning-parts nil)
                (usage nil)
                (payload-error nil)
                proc)
            (condition-case err
                (progn
                  (setq
                   proc
                   (chat-stream-request
                    provider messages #'ignore
                    (plist-put
                     (plist-put (copy-tree prepared) :on-reasoning nil)
                     :on-payload
                     (lambda (json-string)
                       (chat-model-runtime--stream-payload
                        provider json-string emit
                        (lambda (text) (push text text-parts))
                        (lambda (reasoning) (push reasoning reasoning-parts))
                        (lambda (update)
                          (setq usage
                                (chat-model-runtime--merge-usage usage update)))
                        (lambda (message) (setq payload-error message)))))))
                  (let ((inner (process-sentinel proc)))
                    (set-process-sentinel
                     proc
                     (lambda (process event)
                       (when inner
                         (condition-case nil
                             (funcall inner process event)
                           (error nil)))
                       (unless finished
                         (cond
                          ((string-match-p
                            "abnormally\\|failed\\|killed\\|deleted" event)
                           (funcall finish-error
                                    (or payload-error (string-trim event))))
                          ((string-match-p "finished\\|exited" event)
                           (let ((stream-error
                                  (or payload-error
                                      (process-get process
                                                   'chat-stream-http-error))))
                             (if stream-error
                                 (funcall finish-error stream-error)
                               (let* ((native
                                       (chat-stream-native-result process))
                                      (content
                                       (apply #'concat (nreverse text-parts)))
                                      (reasoning
                                       (apply #'concat
                                              (nreverse reasoning-parts)))
                                      (result
                                       (append
                                        (list :content content
                                              :reasoning reasoning
                                              :usage usage
                                              :raw-request nil
                                              :raw-response nil)
                                        native)))
                                 (funcall finish 'completed
                                          (list
                                           :finish-reason
                                           (plist-get native :finish-reason)
                                           :usage usage
                                           :result result)))))))))))
                  proc)
              (error
               (funcall finish-error (error-message-string err))
               nil)))
        (condition-case err
            (chat-llm-request-async
             provider messages
             (lambda (result)
               (unless finished
                 (chat-model-runtime--response-events result emit)
                 (funcall finish 'completed
                          (list :finish-reason
                                (plist-get result :finish-reason)
                                :usage (plist-get result :usage)
                                :result result))))
             (lambda (message) (funcall finish-error message))
             prepared)
          (error
           (funcall finish-error (error-message-string err))
           nil))))))

(defun chat-model-request-result
    (provider messages success-callback error-callback &optional options)
  "Compatibility result API implemented over normalized model events."
  (chat-model-request-events
   provider messages
   (lambda (event)
     (pcase (chat-model-event-type event)
       ('completed
        (funcall success-callback
                 (plist-get (chat-model-event-payload event) :result)))
       ('error
        (funcall error-callback
                 (plist-get (chat-model-event-payload event) :message)))))
   (plist-put (copy-tree options) :stream nil)))

(defun chat-model-stream
    (provider messages callback &optional options)
  "Compatibility chunk API implemented over normalized model events."
  (chat-model-request-events
   provider messages
   (lambda (event)
     (pcase (chat-model-event-type event)
       ('text-delta
        (funcall callback
                 (plist-get (chat-model-event-payload event) :delta)))
       ('completed (funcall callback nil))
       ('error
        (funcall callback nil)
        (error "%s" (plist-get (chat-model-event-payload event) :message)))))
   (plist-put (copy-tree options) :stream t)))

(provide 'chat-model-runtime)
;;; chat-model-runtime.el ends here
