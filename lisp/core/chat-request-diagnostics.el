;;; chat-request-diagnostics.el --- Request diagnostics -*- lexical-binding: t -*-

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup chat-request-diagnostics nil
  "Request diagnostics for chat.el."
  :group 'chat)

(defcustom chat-request-diagnostics-stall-threshold 15
  "Seconds before a request is considered stalled."
  :type 'integer
  :group 'chat-request-diagnostics)

(cl-defstruct chat-request-trace
  id
  mode
  provider
  model
  phase
  started-at
  updated-at
  timeout
  transport
  handle
  process
  stream-chunk-count
  last-chunk-at
  last-error
  last-event
  metadata
  events)

(defvar chat-request-diagnostics--traces (make-hash-table :test 'equal))

(defun chat-request-diagnostics--generate-id ()
  "Return a fresh request id."
  (format "req-%s-%s"
          (format-time-string "%Y%m%d%H%M%S")
          (random 1000000)))

(defun chat-request-diagnostics--phase-for-event (event-type)
  "Return phase symbol for EVENT-TYPE."
  (pcase event-type
    ('request-created 'created)
    ('request-dispatched 'waiting)
    ('timeout-armed 'waiting)
    ('response-received 'processing)
    ('stream-started 'streaming)
    ('stream-chunk 'streaming)
    ('tool-loop-step 'tool-loop)
    ('completed 'completed)
    ('cancelled 'cancelled)
    ('timeout 'failed)
    ('error 'failed)
    (_ nil)))

(defun chat-request-diagnostics-create (mode provider model &optional metadata)
  "Create a new request trace for MODE, PROVIDER, MODEL, and METADATA."
  (let* ((now (current-time))
         (id (chat-request-diagnostics--generate-id))
         (trace (make-chat-request-trace
                 :id id
                 :mode mode
                 :provider provider
                 :model model
                 :phase 'created
                 :started-at now
                 :updated-at now
                 :metadata metadata
                 :events nil)))
    (puthash id trace chat-request-diagnostics--traces)
    (chat-request-diagnostics-record id 'request-created)
    id))

(defun chat-request-diagnostics-get (id)
  "Return request trace for ID."
  (gethash id chat-request-diagnostics--traces))

(defun chat-request-diagnostics-clear (id)
  "Remove request trace ID."
  (remhash id chat-request-diagnostics--traces))

(defun chat-request-diagnostics-record (id event-type &rest props)
  "Append EVENT-TYPE with PROPS to request trace ID."
  (let ((trace (chat-request-diagnostics-get id)))
    (when trace
      (let* ((now (current-time))
             (phase (or (plist-get props :phase)
                        (chat-request-diagnostics--phase-for-event event-type)))
             (event (append (list :type event-type :time now) props)))
        (setf (chat-request-trace-updated-at trace) now)
        (setf (chat-request-trace-last-event trace) event)
        (when phase
          (setf (chat-request-trace-phase trace) phase))
        (when (plist-member props :timeout)
          (setf (chat-request-trace-timeout trace) (plist-get props :timeout)))
        (when (plist-member props :transport)
          (setf (chat-request-trace-transport trace) (plist-get props :transport)))
        (when (plist-member props :handle)
          (setf (chat-request-trace-handle trace) (plist-get props :handle)))
        (when (plist-member props :process)
          (setf (chat-request-trace-process trace) (plist-get props :process)))
        (when (plist-member props :error)
          (setf (chat-request-trace-last-error trace) (plist-get props :error)))
        (when (eq event-type 'stream-chunk)
          (setf (chat-request-trace-stream-chunk-count trace)
                (1+ (or (chat-request-trace-stream-chunk-count trace) 0)))
          (setf (chat-request-trace-last-chunk-at trace) now))
        (setf (chat-request-trace-events trace)
              (append (chat-request-trace-events trace) (list event)))
        trace))))

(defun chat-request-diagnostics-snapshot (id)
  "Return a plist snapshot for request ID."
  (let ((trace (chat-request-diagnostics-get id)))
    (when trace
      (list
       :id (chat-request-trace-id trace)
       :mode (chat-request-trace-mode trace)
       :provider (chat-request-trace-provider trace)
       :model (chat-request-trace-model trace)
       :phase (chat-request-trace-phase trace)
       :started-at (chat-request-trace-started-at trace)
       :updated-at (chat-request-trace-updated-at trace)
       :timeout (chat-request-trace-timeout trace)
       :transport (chat-request-trace-transport trace)
       :stream-chunk-count (or (chat-request-trace-stream-chunk-count trace) 0)
       :last-chunk-at (chat-request-trace-last-chunk-at trace)
       :last-error (chat-request-trace-last-error trace)
       :last-event (chat-request-trace-last-event trace)
       :handle-live-p (let ((handle (chat-request-trace-handle trace)))
                        (and handle
                             (bufferp handle)
                             (buffer-live-p handle)))
       :process-live-p (let ((process (chat-request-trace-process trace)))
                         (and process
                              (processp process)
                              (process-live-p process)))
       :events (chat-request-trace-events trace)))))

(defun chat-request-diagnostics-latest ()
  "Return the most recently updated trace."
  (let (latest)
    (maphash
     (lambda (_id trace)
       (when (or (null latest)
                 (time-less-p (chat-request-trace-updated-at latest)
                              (chat-request-trace-updated-at trace)))
         (setq latest trace)))
     chat-request-diagnostics--traces)
    latest))

(defun chat-request-diagnostics--seconds-since (time)
  "Return seconds since TIME."
  (when time
    (float-time (time-subtract (current-time) time))))

(defun chat-request-diagnostics-stall-message (id)
  "Return a user facing stall message for request ID."
  (let* ((snapshot (chat-request-diagnostics-snapshot id))
         (phase (plist-get snapshot :phase))
         (age (chat-request-diagnostics--seconds-since
               (plist-get snapshot :updated-at)))
         (chunk-count (plist-get snapshot :stream-chunk-count)))
    (when (and age
               (> age chat-request-diagnostics-stall-threshold))
      (pcase phase
        ('waiting
         "Still waiting for provider response.")
        ('streaming
         (if (> chunk-count 0)
             "Stream has stalled without a new chunk."
           "Stream started but no chunks have arrived yet."))
        ('tool-loop
         "Waiting for tool follow-up resolution.")
        (_ nil)))))

(defun chat-request-diagnostics--format-time (time)
  "Return a readable TIME string."
  (if time
      (format-time-string "%Y-%m-%d %H:%M:%S" time)
    "n/a"))

(defun chat-request-diagnostics-format (id)
  "Return a formatted diagnostics string for request ID."
  (let ((snapshot (chat-request-diagnostics-snapshot id)))
    (if (null snapshot)
        (format "No request diagnostics found for %s" id)
      (concat
       (format "Request: %s\n" (plist-get snapshot :id))
       (format "Mode: %s\n" (plist-get snapshot :mode))
       (format "Provider: %s\n" (plist-get snapshot :provider))
       (format "Model: %s\n" (plist-get snapshot :model))
       (format "Phase: %s\n" (plist-get snapshot :phase))
       (format "Started: %s\n" (chat-request-diagnostics--format-time
                                (plist-get snapshot :started-at)))
       (format "Updated: %s\n" (chat-request-diagnostics--format-time
                                (plist-get snapshot :updated-at)))
       (format "Timeout: %s\n" (or (plist-get snapshot :timeout) "n/a"))
       (format "Transport: %s\n" (or (plist-get snapshot :transport) "n/a"))
       (format "Handle live: %s\n" (if (plist-get snapshot :handle-live-p) "yes" "no"))
       (format "Process live: %s\n" (if (plist-get snapshot :process-live-p) "yes" "no"))
       (format "Stream chunks: %s\n" (plist-get snapshot :stream-chunk-count))
       (format "Last chunk: %s\n" (chat-request-diagnostics--format-time
                                   (plist-get snapshot :last-chunk-at)))
       (when-let ((last-error (plist-get snapshot :last-error)))
         (format "Last error: %s\n" last-error))
       "\nEvents:\n"
       (mapconcat
        (lambda (event)
          (format "- %s %s %s"
                  (chat-request-diagnostics--format-time (plist-get event :time))
                  (plist-get event :type)
                  (or (plist-get event :summary)
                      (plist-get event :phase)
                      "")))
        (plist-get snapshot :events)
        "\n")))))

(defun chat-request-diagnostics-show (id)
  "Show diagnostics buffer for request ID."
  (interactive "sRequest ID: ")
  (let ((buffer (get-buffer-create (format "*chat-request:%s*" id))))
    (with-current-buffer buffer
      (erase-buffer)
      (insert (chat-request-diagnostics-format id))
      (goto-char (point-min))
      (view-mode 1))
    (pop-to-buffer buffer)))

(provide 'chat-request-diagnostics)
