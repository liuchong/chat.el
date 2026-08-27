;;; chat-model-event.el --- Normalized model transport events -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; Author: chat.el contributors
;; Keywords: llm, runtime, events

;;; Commentary:

;; Every model transport projects into this event vocabulary.  Raw protocol
;; objects remain adapter-local; the runtime sees stable deltas, usage and
;; terminal outcomes with request identity and ordering.

;;; Code:

(require 'cl-lib)

(defconst chat-model-event-schema-version 1
  "Current normalized model event schema version.")

(defconst chat-model-event-types
  '(started text-delta reasoning-delta tool-call-delta usage completed error)
  "Stable model transport event types.")

(cl-defstruct
    (chat-model-event
     (:constructor chat-model-event-create
                   (&key
                    (schema-version chat-model-event-schema-version)
                    id type timestamp-ms request-id provider model sequence
                    payload)))
  "One normalized event emitted by a model request."
  schema-version id type timestamp-ms request-id provider model sequence payload)

(defun chat-model-event--id ()
  "Return a process-local unique model event id."
  (format "model-%x-%x-%x"
          (truncate (* 1000 (float-time)))
          (emacs-pid)
          (random most-positive-fixnum)))

(defun chat-model-event-make
    (type provider model request-id sequence &optional payload)
  "Create a normalized TYPE event for PROVIDER, MODEL and REQUEST-ID."
  (unless (memq type chat-model-event-types)
    (error "Unknown model event type: %S" type))
  (chat-model-event-create
   :id (chat-model-event--id)
   :type type
   :timestamp-ms (truncate (* 1000 (float-time)))
   :request-id request-id
   :provider provider
   :model model
   :sequence sequence
   :payload payload))

(defun chat-model-event-terminal-p (event)
  "Return non-nil when EVENT closes its model request."
  (memq (chat-model-event-type event) '(completed error)))

(defun chat-model-event--field (object key)
  "Return KEY from alist or plist OBJECT, accepting string keys."
  (cond
   ((not (listp object)) nil)
   ((keywordp (car-safe object)) (plist-get object key))
   (t (or (alist-get key object)
          (cdr (assoc (symbol-name key) object))))))

(defun chat-model-event-normalize-usage (data)
  "Return normalized usage from protocol DATA, or nil.

The result preserves the raw usage object and maps common OpenAI and
Anthropic counters onto one token vocabulary."
  (let* ((message (chat-model-event--field data 'message))
         (usage (or (chat-model-event--field data 'usage)
                    (chat-model-event--field message 'usage)))
         (details (chat-model-event--field usage 'prompt_tokens_details))
         (input (or (chat-model-event--field usage 'input_tokens)
                    (chat-model-event--field usage 'prompt_tokens)))
         (output (or (chat-model-event--field usage 'output_tokens)
                     (chat-model-event--field usage 'completion_tokens)))
         (total (or (chat-model-event--field usage 'total_tokens)
                    (and (numberp input) (numberp output) (+ input output))))
         (cache-read
          (or (chat-model-event--field usage 'cache_read_input_tokens)
              (chat-model-event--field details 'cached_tokens)))
         (cache-write
          (chat-model-event--field usage 'cache_creation_input_tokens)))
    (when usage
      (list :input-tokens input
            :output-tokens output
            :total-tokens total
            :cache-read-tokens cache-read
            :cache-write-tokens cache-write
            :raw usage))))

(provide 'chat-model-event)
;;; chat-model-event.el ends here
