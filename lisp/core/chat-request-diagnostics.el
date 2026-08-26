;;; chat-request-diagnostics.el --- Request diagnostics -*- lexical-binding: t -*-

;;; Code:

(require 'cl-lib)
(require 'seq)
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
  reasoning-count
  reasoning-chars
  tools-in-flight
  tool-started-at
  running-tool
  last-error
  last-event
  metadata
  events)

(defvar chat-request-diagnostics--traces (make-hash-table :test 'equal))
(defvar chat-request-diagnostics--observers (make-hash-table :test 'equal))

(defun chat-request-diagnostics--pending-approval-event (tool-events)
  "Return the first pending approval event from TOOL-EVENTS."
  (seq-find
   (lambda (event)
     (eq (plist-get event :type) 'approval-pending))
   tool-events))

(defun chat-request-diagnostics--latest-tool-event (tool-events)
  "Return the latest notable tool event from TOOL-EVENTS."
  (car (last (seq-filter
              (lambda (event)
                (memq (plist-get event :type)
                      '(tool-call tool-result tool-error approval approval-pending)))
              tool-events))))

(defun chat-request-diagnostics--handle-live-p (handle)
  "Return non-nil when HANDLE is a live buffer handle."
  (and handle
       (bufferp handle)
       (buffer-live-p handle)))

(defun chat-request-diagnostics--process-live-p (process)
  "Return non-nil when PROCESS is a live process."
  (and process
       (processp process)
       (process-live-p process)))

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
    ('tool-started 'tool-loop)
    ('tool-finished 'tool-loop)
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
  (remhash id chat-request-diagnostics--observers)
  (remhash id chat-request-diagnostics--traces))

(defun chat-request-diagnostics-subscribe (id observer)
  "Subscribe OBSERVER to updates for request ID."
  (puthash id
           (cons observer (gethash id chat-request-diagnostics--observers))
           chat-request-diagnostics--observers)
  observer)

(defun chat-request-diagnostics-unsubscribe (id observer)
  "Unsubscribe OBSERVER from request ID."
  (let ((observers (gethash id chat-request-diagnostics--observers)))
    (if observers
        (let ((remaining (delq observer (copy-sequence observers))))
          (if remaining
              (puthash id remaining chat-request-diagnostics--observers)
            (remhash id chat-request-diagnostics--observers)))
      nil)))

(defcustom chat-request-diagnostics-max-events 200
  "Maximum events retained per request trace.
Events are stored newest first internally and oldest events are
dropped once the limit is exceeded."
  :type 'integer
  :group 'chat)

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
        ;; Reasoning counts as arriving data.  It was recorded nowhere
        ;; before, so a model that thought for a minute looked identical to
        ;; one that had died, and the stall notice said no chunks had
        ;; arrived while reasoning chunks were arriving the whole time.
        (when (eq event-type 'stream-reasoning)
          (setf (chat-request-trace-reasoning-count trace)
                (1+ (or (chat-request-trace-reasoning-count trace) 0)))
          ;; `:chars' is this chunk's length, so it accumulates; assigning
          ;; it would report the size of the last chunk as the total.
          (setf (chat-request-trace-reasoning-chars trace)
                (+ (or (chat-request-trace-reasoning-chars trace) 0)
                   (or (plist-get props :chars) 0)))
          (setf (chat-request-trace-last-chunk-at trace) now))
        ;; A tool that has started and not finished is why the request has
        ;; gone quiet.  Counted rather than flagged, because a step can
        ;; call several tools and a flag cleared by the first result would
        ;; report the rest as silence.
        (when (eq event-type 'tool-started)
          (setf (chat-request-trace-tools-in-flight trace)
                (1+ (or (chat-request-trace-tools-in-flight trace) 0)))
          (setf (chat-request-trace-tool-started-at trace) now)
          (setf (chat-request-trace-running-tool trace)
                (plist-get props :tool)))
        (when (eq event-type 'tool-finished)
          (setf (chat-request-trace-tools-in-flight trace)
                (max 0 (1- (or (chat-request-trace-tools-in-flight trace) 0))))
          (when (zerop (chat-request-trace-tools-in-flight trace))
            (setf (chat-request-trace-tool-started-at trace) nil)
            (setf (chat-request-trace-running-tool trace) nil)))
        (let ((events (cons event (chat-request-trace-events trace))))
          (setf (chat-request-trace-events trace)
                (if (> (length events) chat-request-diagnostics-max-events)
                    (seq-take events chat-request-diagnostics-max-events)
                  events)))
        (dolist (observer (gethash id chat-request-diagnostics--observers))
          (funcall observer id trace event))
        trace))))

(defun chat-request-diagnostics-record-tool-event (id event)
  "Record tool EVENT against request ID as tool activity.

Takes the tool event the caller already has rather than asking it to
count.  Which tool events mean \"work started\" and which mean \"work
finished\" is this module's question, and a caller that answered it
separately would be a second place for the two to disagree."
  (when-let* ((type (plist-get event :type))
              (tool (or (plist-get event :tool) "tool")))
    (pcase type
      ('tool-call
       (chat-request-diagnostics-record
        id 'tool-started
        :tool tool
        :summary (format "Running %s" tool)))
      ((or 'tool-result 'tool-error)
       (chat-request-diagnostics-record
        id 'tool-finished
        :tool tool
        :summary (format "%s from %s"
                         (if (eq type 'tool-error) "Error" "Result")
                         tool))))))

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
       :reasoning-count (or (chat-request-trace-reasoning-count trace) 0)
       :reasoning-chars (or (chat-request-trace-reasoning-chars trace) 0)
       :tools-in-flight (or (chat-request-trace-tools-in-flight trace) 0)
       :tool-started-at (chat-request-trace-tool-started-at trace)
       :running-tool (chat-request-trace-running-tool trace)
       :last-error (chat-request-trace-last-error trace)
       :last-event (chat-request-trace-last-event trace)
       :handle-live-p (chat-request-diagnostics--handle-live-p
                       (chat-request-trace-handle trace))
       :process-live-p (chat-request-diagnostics--process-live-p
                        (chat-request-trace-process trace))
       :events (reverse (chat-request-trace-events trace))))))

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
  "Return a user facing stall message for request ID, or nil.

Silence with a known cause is not a stall.  A tool that is still running
is the commonest of those causes and used to produce the worst message in
the interface: a subagent working for two and a half minutes was reported
as \"Stream has stalled without a new chunk\", which named the wrong
component, implied a failure, and was read as one.  The stream had
finished normally; something the stream asked for was in progress."
  (let* ((snapshot (chat-request-diagnostics-snapshot id))
         (phase (plist-get snapshot :phase))
         (age (chat-request-diagnostics--seconds-since
               (plist-get snapshot :updated-at)))
         (chunk-count (plist-get snapshot :stream-chunk-count))
         (reasoning-count (or (plist-get snapshot :reasoning-count) 0)))
    (when (and age
               (> age chat-request-diagnostics-stall-threshold)
               (zerop (or (plist-get snapshot :tools-in-flight) 0)))
      (pcase phase
        ('waiting
         "Still waiting for provider response.")
        ('streaming
         (cond
          ((> chunk-count 0) "Stream has stalled without a new chunk.")
          ;; Reasoning updates `last-chunk-at', so reaching here with a
          ;; reasoning count means thinking has stopped too.
          ((> reasoning-count 0) "Reasoning has stalled without new output.")
          (t "Stream started but no chunks have arrived yet.")))
        ('tool-loop
         "Waiting for tool follow-up resolution.")
        (_ nil)))))

(defun chat-request-diagnostics-live-detail (snapshot &optional tool-events fallback)
  "Return a concise live status string for SNAPSHOT and TOOL-EVENTS.
FALLBACK is used when SNAPSHOT does not provide a better detail."
  (let* ((request-id (plist-get snapshot :id))
         (phase (plist-get snapshot :phase))
         (chunk-count (plist-get snapshot :stream-chunk-count))
         (last-chunk-at (plist-get snapshot :last-chunk-at))
         (chunk-age (and last-chunk-at
                         (truncate
                          (chat-request-diagnostics--seconds-since last-chunk-at))))
         (last-event (plist-get snapshot :last-event))
         (last-summary (plist-get last-event :summary))
         (stalled (and request-id
                       (chat-request-diagnostics-stall-message request-id)))
         (pending-approval
          (chat-request-diagnostics--pending-approval-event tool-events))
         (latest-tool-event
          (chat-request-diagnostics--latest-tool-event tool-events)))
    (cond
     (pending-approval
      (format "Approval pending for %s"
              (plist-get pending-approval :tool)))
     (stalled stalled)
     ((eq phase 'streaming)
      (let ((reasoning-count (or (plist-get snapshot :reasoning-count) 0))
            (reasoning-chars (or (plist-get snapshot :reasoning-chars) 0))
            (waited (truncate
                     (or (chat-request-diagnostics--seconds-since
                          (plist-get snapshot :started-at))
                         0))))
        (cond
         ((> chunk-count 0)
          (format "Receiving response (%d chunks, last %ss ago)"
                  chunk-count
                  (or chunk-age 0)))
         ;; Thinking is work, and saying so is the difference between a
         ;; reader who waits and a reader who assumes a hang.
         ((> reasoning-count 0)
          (format "Thinking (%d chars, %ss elapsed)" reasoning-chars waited))
         ;; The seconds are the point: a number that moves says the request
         ;; is alive, and a first token can be twenty seconds out on a large
         ;; prompt.
         (t (format "Waiting for the first token (%ss)" waited)))))
     ((eq phase 'tool-loop)
      (or
       ;; A running tool, with a number that moves.  This is the case the
       ;; stall notice used to cover, and covering it with a static
       ;; summary instead would trade a wrong explanation for none: the
       ;; reader's question during a long tool call is whether anything is
       ;; still happening, and only the seconds answer it.
       (when-let* ((running (plist-get snapshot :running-tool))
                   (since (plist-get snapshot :tool-started-at)))
         (format "Running %s (%ss)"
                 running
                 (truncate (or (chat-request-diagnostics--seconds-since since)
                               0))))
       last-summary
       (pcase (plist-get latest-tool-event :type)
            ('tool-call
             (format "Running %s"
                     (plist-get latest-tool-event :tool)))
            ('tool-result
             (format "Received result from %s"
                     (plist-get latest-tool-event :tool)))
            ('tool-error
             (format "Tool failed: %s"
                     (plist-get latest-tool-event :tool)))
            (_ nil))
          "Resolving tool follow-up"))
     ((eq phase 'waiting)
      (or last-summary "Waiting for provider response"))
     ((eq phase 'processing)
      (or last-summary "Processing response"))
     ((eq phase 'created)
      (or last-summary "Preparing request"))
     ((eq phase 'completed)
      (or last-summary "Completed"))
     ((eq phase 'cancelled)
      (or last-summary "Cancelled"))
     ((eq phase 'failed)
      (or (plist-get snapshot :last-error)
          last-summary
          "Request failed"))
     (t (or last-summary fallback)))))

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
