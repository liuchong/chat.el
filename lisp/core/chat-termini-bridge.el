;;; chat-termini-bridge.el --- Termini App Server client -*- lexical-binding: t; -*-

;;; Commentary:

;; Optional JSON-RPC bridge over the Termini App Server stdio transport.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'chat-execution)
(require 'chat-session)

(defgroup chat-termini nil
  "Termini App Server integration."
  :group 'chat)

(defconst chat-termini-client-schema-version 1)
(defconst chat-termini-supported-protocol-versions '("2026-07-08"))
(defconst chat-termini-required-methods
  '("initialize" "shutdown" "session/list" "session/open" "command/run"
    "message/list" "job/list" "job/tail" "job/cancel"))
(defconst chat-termini-terminal-job-statuses
  '(succeeded failed timed_out cancelled interrupted rejected))
(defconst chat-termini-job-statuses
  (append '(accepted running) chat-termini-terminal-job-statuses))

(defconst chat-termini--empty-object (make-hash-table :test 'equal)
  "JSON object used for methods with no parameters.")

(defcustom chat-termini-command
  '("termini" "app-server" "--listen" "stdio")
  "Command argv used to start a Termini App Server sidecar."
  :type '(repeat string)
  :group 'chat-termini)

(defcustom chat-termini-request-timeout 10
  "Default App Server request timeout in seconds."
  :type 'number
  :group 'chat-termini)

(defcustom chat-termini-max-line-bytes (* 2 1024 1024)
  "Maximum bytes accepted for one JSON-RPC line."
  :type 'integer
  :group 'chat-termini)

(defcustom chat-termini-max-text-chars (* 1024 1024)
  "Maximum characters retained in one remote text projection."
  :type 'integer
  :group 'chat-termini)

(defcustom chat-termini-max-notifications 1000
  "Maximum bounded notification summaries retained per connection."
  :type 'integer
  :group 'chat-termini)

(defcustom chat-termini-max-attachment-bytes (* 25 1024 1024)
  "Maximum decoded bytes returned by one explicit attachment read."
  :type 'integer
  :group 'chat-termini)

(defcustom chat-termini-max-stderr-chars (* 64 1024)
  "Maximum stderr tail retained for one Termini connection."
  :type 'integer
  :group 'chat-termini)

(define-error 'chat-termini-error "Termini bridge error")
(define-error 'chat-termini-protocol-error "Termini protocol error"
  'chat-termini-error)
(define-error 'chat-termini-capability-error "Termini capability error"
  'chat-termini-error)
(define-error 'chat-termini-rpc-error "Termini RPC error"
  'chat-termini-error)

(cl-defstruct (chat-termini-client
               (:constructor chat-termini-client-create-record))
  schema-version id command process execution status generation next-id
  input-buffer pending responses methods events protocol-version notifications
  observers seen-event-ids stderr-process stderr-text last-error)

(cl-defstruct chat-termini-session
  id display-name cwd project-id last-activity-at active-job-count)

(cl-defstruct chat-termini-attachment
  id file-name kind mime-type size-bytes)

(cl-defstruct chat-termini-message
  id runtime-session-id role text timestamp-ms content-format content-category
  work-kind attachments)

(cl-defstruct chat-termini-job
  id runtime-session-id kind tool status command-preview cwd accepted-at-ms
  started-at-ms completed-at-ms duration-ms exit-code failure-reason)

(cl-defstruct chat-termini-tail
  job-id runtime-session-id text truncated next-cursor status)

(defvar chat-termini-default-client nil
  "Default interactive Termini client.")

(defun chat-termini-client-create (&rest options)
  "Create a disconnected client from OPTIONS."
  (chat-termini-client-create-record
   :schema-version chat-termini-client-schema-version
   :id (or (plist-get options :id)
           (format "termini-%06x" (random #x1000000)))
   :command (copy-sequence (or (plist-get options :command)
                               chat-termini-command))
   :status 'created :generation 0 :next-id 0 :input-buffer ""
   :pending (make-hash-table :test 'equal)
   :responses (make-hash-table :test 'equal)
   :methods nil :events nil :notifications nil :observers nil
   :stderr-text ""
   :seen-event-ids (make-hash-table :test 'equal)))

(defun chat-termini--bounded-string (value limit field &optional required)
  "Return bounded string VALUE for FIELD with LIMIT."
  (when (and required
             (not (and (stringp value) (not (string-empty-p value)))))
    (signal 'chat-termini-protocol-error
            (list (format "Missing %s" field))))
  (when value
    (unless (stringp value)
      (signal 'chat-termini-protocol-error
              (list (format "Invalid %s" field))))
    (truncate-string-to-width value limit nil nil t)))

(defun chat-termini--record-error (client kind message)
  "Record bounded KIND and MESSAGE on CLIENT."
  (setf (chat-termini-client-last-error client)
        `((kind . ,kind)
          (message . ,(truncate-string-to-width
                        (format "%s" message) 512 nil nil t))))
  (chat-termini-client-last-error client))

(defun chat-termini--next-id (client)
  "Return CLIENT's next numeric request ID."
  (setf (chat-termini-client-next-id client)
        (1+ (chat-termini-client-next-id client))))

(defun chat-termini--request (client method &optional params)
  "Return one JSON-RPC request for CLIENT, METHOD and PARAMS."
  `((jsonrpc . "2.0")
    (id . ,(chat-termini--next-id client))
    (method . ,method)
    (params . ,(or params chat-termini--empty-object))))

(defun chat-termini--decode-line (line)
  "Decode one bounded JSON-RPC LINE."
  (when (> (string-bytes line) chat-termini-max-line-bytes)
    (signal 'chat-termini-protocol-error
            (list "JSON-RPC line exceeds the configured limit")))
  (let ((json-object-type 'alist)
        (json-array-type 'list)
        (json-key-type 'symbol))
    (json-read-from-string line)))

(defun chat-termini--cancel-pending-timer (pending)
  "Cancel the timer in PENDING when present."
  (let ((timer (plist-get pending :timer)))
    (when (timerp timer) (cancel-timer timer))))

(defun chat-termini--rpc-condition (rpc-error)
  "Return a bounded condition data list for RPC-ERROR."
  (let* ((message (or (alist-get 'message rpc-error) "RPC error"))
         (code (alist-get 'code rpc-error))
         (data (alist-get 'data rpc-error))
         (app-code (and (listp data) (alist-get 'appCode data))))
    (list (truncate-string-to-width (format "%s" message) 512 nil nil t)
          code app-code)))

(defun chat-termini--response-p (message)
  "Return non-nil when MESSAGE is a JSON-RPC response."
  (assq 'id message))

(defun chat-termini--notification-summary (method params)
  "Return a bounded summary for notification METHOD and PARAMS."
  (delq nil
        `((method . ,(chat-termini--bounded-string method 128 "method" t))
          ,(and (listp params)
                (alist-get 'eventId params)
                (cons 'eventId
                      (chat-termini--bounded-string
                       (alist-get 'eventId params) 256 "eventId")))
          ,(and (listp params)
                (alist-get 'runtimeSessionId params)
                (cons 'runtimeSessionId
                      (chat-termini--bounded-string
                       (alist-get 'runtimeSessionId params) 256
                       "runtimeSessionId")))
          ,(and (listp params)
                (alist-get 'jobId params)
                (cons 'jobId
                      (chat-termini--bounded-string
                       (alist-get 'jobId params) 256 "jobId"))))))

(defun chat-termini-add-observer (client observer)
  "Add notification OBSERVER to CLIENT."
  (unless (functionp observer) (error "Observer is not callable"))
  (cl-pushnew observer (chat-termini-client-observers client))
  observer)

(defun chat-termini-remove-observer (client observer)
  "Remove notification OBSERVER from CLIENT."
  (setf (chat-termini-client-observers client)
        (delq observer (chat-termini-client-observers client))))

(defun chat-termini--handle-notification (client message)
  "Deliver one notification MESSAGE for CLIENT."
  (let* ((method (alist-get 'method message))
         (params (alist-get 'params message))
         (event-id (and (listp params) (alist-get 'eventId params)))
         (seen (chat-termini-client-seen-event-ids client)))
    (unless (and event-id (gethash event-id seen))
      (when event-id
        (when (>= (hash-table-count seen) chat-termini-max-notifications)
          (clrhash seen))
        (puthash event-id t seen))
      (push (chat-termini--notification-summary method params)
            (chat-termini-client-notifications client))
      (when (> (length (chat-termini-client-notifications client))
               chat-termini-max-notifications)
        (setf (chat-termini-client-notifications client)
              (seq-take (chat-termini-client-notifications client)
                        chat-termini-max-notifications)))
      (dolist (observer (chat-termini-client-observers client))
        (condition-case err
            (funcall observer method params)
          (error
           (chat-termini--record-error
            client 'observer_error (error-message-string err))))))))

(defun chat-termini--handle-response (client message)
  "Record one response MESSAGE for CLIENT."
  (let* ((id (alist-get 'id message))
         (responses (chat-termini-client-responses client))
         (pending-table (chat-termini-client-pending client))
         (pending (gethash id pending-table)))
    (if (gethash id responses)
        (chat-termini--record-error client 'duplicate_response
                                    (format "Duplicate response %s" id))
      (if pending
          (progn
            (puthash id message responses)
            (remhash id pending-table)
            (chat-termini--cancel-pending-timer pending)
            (unless (plist-get pending :sync)
              (if-let* ((rpc-error (alist-get 'error message)))
                  (funcall (plist-get pending :error)
                           (chat-termini--rpc-condition rpc-error))
                (funcall (plist-get pending :success)
                         (alist-get 'result message)))))
        (chat-termini--record-error client 'unknown_response
                                    (format "Unknown response %s" id))))))

(defun chat-termini--stderr-filter (client _process chunk)
  "Retain only the bounded stderr tail from CHUNK for CLIENT."
  (let ((text (concat (or (chat-termini-client-stderr-text client) "")
                      chunk)))
    (when (> (length text) chat-termini-max-stderr-chars)
      (setq text (substring text (- (length text)
                                    chat-termini-max-stderr-chars))))
    (setf (chat-termini-client-stderr-text client) text)))

(defun chat-termini--handle-message (client message)
  "Handle decoded JSON-RPC MESSAGE for CLIENT."
  (cond ((chat-termini--response-p message)
         (chat-termini--handle-response client message))
        ((alist-get 'method message)
         (chat-termini--handle-notification client message))
        (t
         (chat-termini--record-error client 'protocol_error
                                     "Unrecognized JSON-RPC message")))
  message)

(defun chat-termini--handle-line (client line)
  "Decode and handle LINE for CLIENT."
  (condition-case err
      (chat-termini--handle-message client (chat-termini--decode-line line))
    (error
     (chat-termini--record-error
      client 'protocol_error (error-message-string err)))))

(defun chat-termini--filter (client _process chunk)
  "Accumulate process CHUNK and deliver complete lines for CLIENT."
  (setf (chat-termini-client-input-buffer client)
        (concat (chat-termini-client-input-buffer client) chunk))
  (let ((parts (split-string (chat-termini-client-input-buffer client) "\n")))
    (setf (chat-termini-client-input-buffer client) (car (last parts)))
    (when (> (string-bytes (chat-termini-client-input-buffer client))
             chat-termini-max-line-bytes)
      (setf (chat-termini-client-input-buffer client) "")
      (chat-termini--record-error
       client 'protocol_error "JSON-RPC input exceeds the configured limit"))
    (dolist (line (butlast parts))
      (unless (string-empty-p (string-trim line))
        (chat-termini--handle-line client line)))))

(defun chat-termini--fail-pending (client message)
  "Fail every pending CLIENT request once with MESSAGE."
  (let ((pending-table (chat-termini-client-pending client)))
    (maphash
     (lambda (_id pending)
       (chat-termini--cancel-pending-timer pending)
       (unless (plist-get pending :sync)
         (funcall (plist-get pending :error) message)))
     pending-table)
    (clrhash pending-table)))

(defun chat-termini--connection-ended (client event)
  "Close transient CLIENT state after process EVENT."
  (chat-termini--fail-pending client (format "Connection ended: %s" event))
  (setf (chat-termini-client-process client) nil
        (chat-termini-client-execution client) nil)
  (unless (eq 'failed (chat-termini-client-status client))
    (setf (chat-termini-client-status client) 'disconnected))
  client)

(defun chat-termini--process-live-p (client)
  "Return non-nil when CLIENT has a live process."
  (let ((process (chat-termini-client-process client)))
    (and (processp process) (process-live-p process))))

(defun chat-termini--send-request (client request)
  "Send REQUEST through CLIENT."
  (unless (chat-termini--process-live-p client)
    (signal 'chat-termini-error (list "Termini client is not connected")))
  (process-send-string
   (chat-termini-client-process client)
   (concat (json-encode request) "\n")))

(defun chat-termini--signal-rpc-error (rpc-error)
  "Signal the bounded RPC-ERROR condition."
  (signal 'chat-termini-rpc-error (chat-termini--rpc-condition rpc-error)))

(defun chat-termini-capability-p (client method)
  "Return non-nil when CLIENT advertised METHOD."
  (member method (chat-termini-client-methods client)))

(defun chat-termini-require-capability (client method)
  "Require ready CLIENT to advertise METHOD."
  (unless (eq 'ready (chat-termini-client-status client))
    (signal 'chat-termini-error (list "Termini client is not ready")))
  (unless (chat-termini-capability-p client method)
    (signal 'chat-termini-capability-error
            (list (format "Termini method is unavailable: %s" method))))
  t)

(defun chat-termini-call (client method &optional params timeout)
  "Call METHOD with PARAMS through CLIENT and return its result."
  (unless (member method '("initialize" "shutdown"))
    (chat-termini-require-capability client method))
  (let* ((request (chat-termini--request client method params))
         (id (alist-get 'id request))
         (deadline (+ (float-time) (or timeout chat-termini-request-timeout)))
         (pending-table (chat-termini-client-pending client))
         response)
    (puthash id '(:sync t) pending-table)
    (condition-case err
        (chat-termini--send-request client request)
      (error
       (remhash id pending-table)
       (signal (car err) (cdr err))))
    (while (and (null (setq response
                             (gethash id
                                      (chat-termini-client-responses client))))
                (< (float-time) deadline)
                (chat-termini--process-live-p client))
      (accept-process-output (chat-termini-client-process client) 0.05))
    (remhash id pending-table)
    (unless response
      (signal 'chat-termini-error
              (list (if (chat-termini--process-live-p client)
                        (format "Timed out waiting for Termini response %s" id)
                      "Termini connection ended before the response"))))
    (remhash id (chat-termini-client-responses client))
    (if-let* ((rpc-error (alist-get 'error response)))
        (chat-termini--signal-rpc-error rpc-error)
      (alist-get 'result response))))

(defun chat-termini--request-timeout (client id)
  "Fail asynchronous CLIENT request ID after timeout."
  (let* ((pending-table (chat-termini-client-pending client))
         (pending (gethash id pending-table)))
    (when pending
      (remhash id pending-table)
      (funcall (plist-get pending :error)
               (format "Timed out waiting for Termini response %s" id)))))

(defun chat-termini-call-async
    (client method params success error-callback &optional timeout)
  "Call METHOD asynchronously and invoke SUCCESS or ERROR-CALLBACK."
  (chat-termini-require-capability client method)
  (let* ((request (chat-termini--request client method params))
         (id (alist-get 'id request))
         (timer (run-at-time
                 (or timeout chat-termini-request-timeout) nil
                 #'chat-termini--request-timeout client id)))
    (puthash id (list :success success :error error-callback :timer timer)
             (chat-termini-client-pending client))
    (condition-case err
        (chat-termini--send-request client request)
      (error
       (chat-termini--request-timeout client id)
       (signal (car err) (cdr err))))
    (list :id id
          :cancel
          (lambda ()
            (let ((pending (gethash id
                                    (chat-termini-client-pending client))))
              (when pending
                (chat-termini--cancel-pending-timer pending)
                (remhash id (chat-termini-client-pending client))))))))

(defun chat-termini-initialize (client)
  "Negotiate CLIENT protocol and capabilities."
  (setf (chat-termini-client-status client) 'connecting)
  (let* ((result
          (chat-termini-call
           client "initialize"
           `((clientInfo . ((name . "chat.el") (version . "0.1.0")))
             (supportedProtocolVersions
              . ,chat-termini-supported-protocol-versions)
             (capabilities
              . ((subscribeEventMethods
                  . ("job/started" "job/completed" "job/failed"
                     "job/log_delta")))))))
         (server-info (alist-get 'serverInfo result))
         (server-name (alist-get 'name server-info))
         (version (alist-get 'negotiatedProtocolVersion result))
         (capabilities (alist-get 'capabilities result))
         (methods (alist-get 'methods capabilities))
         (events (alist-get 'events capabilities)))
    (unless (and (equal "termini" server-name)
                 (member version chat-termini-supported-protocol-versions))
      (setf (chat-termini-client-status client) 'failed)
      (signal 'chat-termini-protocol-error
              (list "Termini protocol negotiation failed")))
    (let ((missing (seq-remove (lambda (method) (member method methods))
                               chat-termini-required-methods)))
      (when missing
        (setf (chat-termini-client-status client) 'failed)
        (signal 'chat-termini-capability-error
                (list (format "Termini is missing required methods: %s"
                              (string-join missing ", "))))))
    (setf (chat-termini-client-protocol-version client) version
          (chat-termini-client-methods client) methods
          (chat-termini-client-events client) events
          (chat-termini-client-status client) 'ready)
    client))

(defun chat-termini--validate-command (command)
  "Validate and return direct argv COMMAND."
  (unless (and (consp command) (seq-every-p #'stringp command)
               (not (string-empty-p (car command))))
    (signal 'chat-termini-error (list "Termini command must be argv")))
  (let ((executable (car command)))
    (unless (or (and (file-name-absolute-p executable)
                     (file-executable-p executable))
                (executable-find executable))
      (signal 'chat-termini-error
              (list (format "Termini executable not found: %s" executable)))))
  command)

(defun chat-termini-start (client)
  "Start and initialize CLIENT."
  (when (chat-termini--process-live-p client)
    (signal 'chat-termini-error (list "Termini client is already connected")))
  (chat-execution-initialize)
  (let* ((command (chat-termini--validate-command
                   (chat-termini-client-command client)))
         (stderr-process
          (make-pipe-process
           :name (format "chat-termini-%s-stderr"
                         (chat-termini-client-id client))
           :buffer nil :noquery t :coding 'utf-8-unix
           :filter (lambda (process chunk)
                     (chat-termini--stderr-filter client process chunk))))
         (request
          (chat-execution-request-from-context
           command :idempotency 'idempotent
           :metadata `((kind . "termini-app-server")
                       (clientId . ,(chat-termini-client-id client)))))
         record)
    (setf (chat-termini-client-generation client)
          (1+ (chat-termini-client-generation client))
          (chat-termini-client-input-buffer client) ""
          (chat-termini-client-stderr-process client) stderr-process
          (chat-termini-client-stderr-text client) ""
          (chat-termini-client-status client) 'connecting
          (chat-termini-client-last-error client) nil
          (chat-termini-client-notifications client) nil)
    (clrhash (chat-termini-client-pending client))
    (clrhash (chat-termini-client-responses client))
    (clrhash (chat-termini-client-seen-event-ids client))
    (condition-case err
        (progn
          (setq record
                (chat-execution-start
                 request
                 :name (format "chat-termini-%s"
                               (chat-termini-client-id client))
                 :buffer nil :stderr stderr-process :connection-type 'pipe
                 :coding 'utf-8-unix :noquery t
                 :filter (lambda (process chunk)
                           (chat-termini--filter client process chunk))
                 :sentinel (lambda (_process event)
                             (chat-termini--connection-ended client event))))
          (setf (chat-termini-client-execution client) record
                (chat-termini-client-process client)
                (chat-execution-native-handle record))
          (chat-termini-initialize client))
      (error
       (setf (chat-termini-client-status client) 'failed)
       (when (and record (chat-execution-record-native-handle record))
         (chat-execution-cancel record "Termini initialization failed"))
       (when (and (processp stderr-process)
                  (process-live-p stderr-process))
         (delete-process stderr-process))
       (setf (chat-termini-client-stderr-process client) nil)
       (signal (car err) (cdr err))))))

(defun chat-termini-disconnect (&optional client)
  "Gracefully disconnect CLIENT or the default client."
  (let ((client (or client chat-termini-default-client)))
    (when client
      (when (and (chat-termini--process-live-p client)
                 (eq 'ready (chat-termini-client-status client)))
        (condition-case nil
            (chat-termini-call client "shutdown"
                               '((reason . "client_exit")) 2)
          (error nil)))
      (let ((record (chat-termini-client-execution client)))
        (when (and record (chat-execution-record-native-handle record))
          (chat-execution-cancel record "Termini client disconnected")))
      (chat-termini--connection-ended client "client disconnect")
      (let ((stderr (chat-termini-client-stderr-process client)))
        (when (and (processp stderr) (process-live-p stderr))
          (delete-process stderr)))
      (setf (chat-termini-client-stderr-process client) nil))
    client))

(defun chat-termini-reconnect (&optional client)
  "Reconnect CLIENT without replaying prior requests."
  (let ((client (or client chat-termini-default-client)))
    (unless client (signal 'chat-termini-error (list "No Termini client")))
    (chat-termini-disconnect client)
    (chat-termini-start client)))

(defun chat-termini--method-call (client method params)
  "Require METHOD and call it with PARAMS through CLIENT."
  (chat-termini-require-capability client method)
  (chat-termini-call client method params))

(defun chat-termini--attachment-from-data (data)
  "Return a validated attachment projection from DATA."
  (let ((size (alist-get 'sizeBytes data)))
    (unless (and (integerp size) (>= size 0))
      (signal 'chat-termini-protocol-error
              (list "Invalid attachment size")))
    (make-chat-termini-attachment
     :id (chat-termini--bounded-string
          (alist-get 'attachmentId data) 256 "attachmentId" t)
     :file-name (chat-termini--bounded-string
                 (alist-get 'fileName data) 512 "fileName" t)
     :kind (intern (or (chat-termini--bounded-string
                        (alist-get 'kind data) 64 "kind") "unknown"))
     :mime-type (chat-termini--bounded-string
                 (alist-get 'mimeType data) 256 "mimeType" t)
     :size-bytes size)))

(defun chat-termini--job-from-data (data)
  "Return a validated job projection from DATA."
  (let ((status (intern (or (alist-get 'status data) ""))))
    (unless (memq status chat-termini-job-statuses)
      (signal 'chat-termini-protocol-error
              (list (format "Unsupported Termini job status: %s" status))))
    (make-chat-termini-job
     :id (chat-termini--bounded-string (alist-get 'jobId data) 256 "jobId" t)
     :runtime-session-id
     (chat-termini--bounded-string
      (alist-get 'runtimeSessionId data) 256 "runtimeSessionId" t)
     :kind (intern (or (chat-termini--bounded-string
                        (alist-get 'kind data) 64 "kind") "unknown"))
     :tool (chat-termini--bounded-string (alist-get 'tool data) 128 "tool")
     :status status
     :command-preview (chat-termini--bounded-string
                       (alist-get 'commandPreview data) 1024 "commandPreview")
     :cwd (chat-termini--bounded-string (alist-get 'cwd data) 4096 "cwd")
     :accepted-at-ms (alist-get 'acceptedAtMs data)
     :started-at-ms (alist-get 'startedAtMs data)
     :completed-at-ms (alist-get 'completedAtMs data)
     :duration-ms (alist-get 'durationMs data)
     :exit-code (alist-get 'exitCode data)
     :failure-reason (chat-termini--bounded-string
                      (alist-get 'failureReason data) 512 "failureReason"))))

(defun chat-termini--session-from-data (data)
  "Return a validated RuntimeSession projection from DATA."
  (make-chat-termini-session
   :id (chat-termini--bounded-string
        (alist-get 'runtimeSessionId data) 256 "runtimeSessionId" t)
   :display-name (chat-termini--bounded-string
                  (alist-get 'displayName data) 512 "displayName")
   :cwd (chat-termini--bounded-string (alist-get 'cwd data) 4096 "cwd")
   :project-id (chat-termini--bounded-string
                (alist-get 'projectId data) 256 "projectId")
   :last-activity-at (or (alist-get 'lastActivityAtMs data)
                         (alist-get 'lastActivityAt data))
   :active-job-count (or (alist-get 'activeJobCount data)
                         (and (assq 'runningJobIds data)
                              (length (or (alist-get 'runningJobIds data) nil)))
                         (length (or (alist-get 'activeJobs data) nil)))))

(defun chat-termini--message-from-data (data)
  "Return a validated message projection from DATA."
  (make-chat-termini-message
   :id (chat-termini--bounded-string
        (alist-get 'messageId data) 256 "messageId" t)
   :runtime-session-id
   (chat-termini--bounded-string
    (alist-get 'runtimeSessionId data) 256 "runtimeSessionId" t)
   :role (intern (or (chat-termini--bounded-string
                      (alist-get 'role data) 32 "role") "unknown"))
   :text (chat-termini--bounded-string
          (or (alist-get 'text data) "") chat-termini-max-text-chars "text")
   :timestamp-ms (alist-get 'timestampMs data)
   :content-format (intern (or (chat-termini--bounded-string
                                (alist-get 'contentFormat data) 32
                                "contentFormat") "plain"))
   :content-category (intern (or (chat-termini--bounded-string
                                  (alist-get 'contentCategory data) 64
                                  "contentCategory") "unknown"))
   :work-kind (and (alist-get 'workKind data)
                   (intern (chat-termini--bounded-string
                            (alist-get 'workKind data) 64 "workKind")))
   :attachments (mapcar #'chat-termini--attachment-from-data
                        (or (alist-get 'attachments data) nil))))

(defun chat-termini-session-list (client &optional params)
  "Return RuntimeSessions visible through CLIENT."
  (let ((result (chat-termini--method-call client "session/list" params)))
    (mapcar #'chat-termini--session-from-data
            (or (alist-get 'sessions result) nil))))

(defun chat-termini-session-open (client params)
  "Open a RuntimeSession through CLIENT with PARAMS."
  (chat-termini--method-call client "session/open" params))

(defun chat-termini-command-run
    (client runtime-session-id text client-message-id)
  "Run Termini command TEXT with numeric CLIENT-MESSAGE-ID."
  (unless (integerp client-message-id)
    (signal 'chat-termini-error
            (list "command/run requires a numeric clientMessageId")))
  (chat-termini--method-call
   client "command/run"
   `((runtimeSessionId . ,runtime-session-id)
     (text . ,text) (clientMessageId . ,client-message-id))))

(defun chat-termini-message-send
    (client runtime-session-id text client-message-id &optional attachment-ids)
  "Send plain TEXT and optional ATTACHMENT-IDS through CLIENT."
  (unless (and (stringp client-message-id)
               (not (string-empty-p client-message-id)))
    (signal 'chat-termini-error
            (list "message/send requires a clientMessageId")))
  (chat-termini--method-call
   client "message/send"
   (delq nil
         `((runtimeSessionId . ,runtime-session-id)
           (text . ,text) (clientMessageId . ,client-message-id)
           ,(and attachment-ids
                 (cons 'attachmentIds attachment-ids))))))

(defun chat-termini-message-list (client runtime-session-id &optional params)
  "Return messages for RUNTIME-SESSION-ID through CLIENT."
  (let ((result
         (chat-termini--method-call
          client "message/list"
          (append `((runtimeSessionId . ,runtime-session-id)) params))))
    (mapcar #'chat-termini--message-from-data
            (or (alist-get 'messages result) nil))))

(defun chat-termini-job-list (client &optional runtime-session-id params)
  "Return jobs visible through CLIENT, optionally scoped to a session."
  (let ((result
         (chat-termini--method-call
          client "job/list"
          (append (and runtime-session-id
                       `((runtimeSessionId . ,runtime-session-id)))
                  params))))
    (mapcar #'chat-termini--job-from-data
            (or (alist-get 'jobs result) nil))))

(defun chat-termini-job-tail
    (client runtime-session-id job-id &optional params)
  "Return bounded tail projection for JOB-ID."
  (let* ((result
          (chat-termini--method-call
           client "job/tail"
           (append `((runtimeSessionId . ,runtime-session-id)
                     (jobId . ,job-id))
                   params)))
         (status (intern (or (alist-get 'status result) ""))))
    (unless (memq status chat-termini-job-statuses)
      (signal 'chat-termini-protocol-error
              (list (format "Unsupported Termini tail status: %s" status))))
    (make-chat-termini-tail
     :job-id (chat-termini--bounded-string
              (alist-get 'jobId result) 256 "jobId" t)
     :runtime-session-id
     (chat-termini--bounded-string
      (alist-get 'runtimeSessionId result) 256 "runtimeSessionId" t)
     :text (chat-termini--bounded-string
            (or (alist-get 'text result) "")
            chat-termini-max-text-chars "text")
     :truncated (eq t (alist-get 'truncated result))
     :next-cursor (chat-termini--bounded-string
                   (alist-get 'nextCursor result) 1024 "nextCursor")
     :status status)))

(defun chat-termini-job-cancel
    (client runtime-session-id &optional job-id client-request-id)
  "Cancel JOB-ID in RUNTIME-SESSION-ID with CLIENT-REQUEST-ID."
  (chat-termini--method-call
   client "job/cancel"
   (delq nil
         `((runtimeSessionId . ,runtime-session-id)
           ,(and job-id (cons 'jobId job-id))
           ,(and client-request-id
                 (cons 'clientRequestId client-request-id))))))

(defun chat-termini-attachment-stage
    (client runtime-session-id path &optional file-name)
  "Stage absolute file PATH for RUNTIME-SESSION-ID."
  (chat-termini-require-capability client "attachment/stage")
  (unless (and (file-name-absolute-p path) (file-regular-p path))
    (signal 'chat-termini-error
            (list "Attachment path must be an absolute regular file")))
  (let ((result
         (chat-termini--method-call
          client "attachment/stage"
          (delq nil
                `((runtimeSessionId . ,runtime-session-id)
                  (path . ,path)
                  ,(and file-name (cons 'fileName file-name)))))))
    (chat-termini--attachment-from-data (alist-get 'attachment result))))

(defun chat-termini-attachment-read (client runtime-session-id attachment-id)
  "Read bounded ATTACHMENT-ID bytes for RUNTIME-SESSION-ID."
  (let* ((result
          (chat-termini--method-call
           client "attachment/read"
           `((runtimeSessionId . ,runtime-session-id)
             (attachmentId . ,attachment-id))))
         (attachment
          (chat-termini--attachment-from-data (alist-get 'attachment result)))
         (encoding (alist-get 'encoding result))
         (encoded (alist-get 'data result)))
    (unless (equal "base64" encoding)
      (signal 'chat-termini-protocol-error
              (list "Unsupported attachment encoding")))
    (when (> (chat-termini-attachment-size-bytes attachment)
             chat-termini-max-attachment-bytes)
      (signal 'chat-termini-protocol-error
              (list "Attachment exceeds the configured byte limit")))
    (unless (and (stringp encoded)
                 (<= (length encoded)
                     (+ 4 (* 4 (ceiling
                                chat-termini-max-attachment-bytes 3)))))
      (signal 'chat-termini-protocol-error
              (list "Encoded attachment exceeds the configured byte limit")))
    (let ((bytes (condition-case nil
                     (base64-decode-string encoded)
                   (error
                    (signal 'chat-termini-protocol-error
                            (list "Invalid attachment base64"))))))
      (when (> (string-bytes bytes) chat-termini-max-attachment-bytes)
        (signal 'chat-termini-protocol-error
                (list "Attachment exceeds the configured byte limit")))
      (list :attachment attachment :bytes bytes
            :truncated (eq t (alist-get 'truncated result))))))

(defun chat-termini-attachment-discard
    (client runtime-session-id attachment-id)
  "Discard staged ATTACHMENT-ID for RUNTIME-SESSION-ID."
  (chat-termini--method-call
   client "attachment/discard"
   `((runtimeSessionId . ,runtime-session-id)
     (attachmentId . ,attachment-id))))

(defun termini-bound-session-id (&optional session)
  "Return the Termini RuntimeSession ID bound to local SESSION."
  (let ((session (or session
                     (and (boundp 'chat--current-session)
                          chat--current-session))))
    (chat-session-metadata-get session 'termini-runtime-session-id)))

(defun termini-bind-session (runtime-session-id &optional session)
  "Bind local SESSION to Termini RUNTIME-SESSION-ID and persist it."
  (let ((session (or session
                     (and (boundp 'chat--current-session)
                          chat--current-session))))
    (unless session (user-error "No local chat session"))
    (chat-termini--bounded-string runtime-session-id 256
                                  "runtimeSessionId" t)
    (chat-session-metadata-set session 'termini-runtime-session-id
                               runtime-session-id)
    (chat-session-save session)
    runtime-session-id))

(defun termini-unbind-session (&optional session)
  "Remove the Termini binding from local SESSION and persist it."
  (let ((session (or session
                     (and (boundp 'chat--current-session)
                          chat--current-session))))
    (unless session (user-error "No local chat session"))
    (chat-session-metadata-set session 'termini-runtime-session-id nil)
    (chat-session-save session)
    nil))

(defun chat-termini-stop-default-client ()
  "Stop the default client during Emacs shutdown."
  (when chat-termini-default-client
    (chat-termini-disconnect chat-termini-default-client)))

(add-hook 'kill-emacs-hook #'chat-termini-stop-default-client)

(provide 'chat-termini-bridge)
;;; chat-termini-bridge.el ends here
