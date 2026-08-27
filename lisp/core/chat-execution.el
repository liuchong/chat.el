;;; chat-execution.el --- Versioned execution backend contract -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;;; Commentary:

;; Durable execution requests and attempts are separate from live Emacs
;; process objects.  Loading records can mark stale work interrupted, but it
;; never starts a process or repeats an external effect.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'chat-event)

(defgroup chat-execution nil
  "Execution backend requests and attempts."
  :group 'chat)

(defconst chat-execution-schema-version 1
  "Current execution request and record schema version.")

(defconst chat-execution-idempotency-classes
  '(read-only idempotent non-idempotent)
  "Retry classifications understood by the execution runtime.")

(defcustom chat-execution-directory
  (expand-file-name "executions/" (expand-file-name "~/.chat/"))
  "Directory containing durable execution records."
  :type 'directory
  :group 'chat-execution)

(defcustom chat-execution-auto-save t
  "When non-nil, persist execution records after every transition."
  :type 'boolean
  :group 'chat-execution)

(define-error 'chat-execution-invalid-request "Invalid execution request")
(define-error 'chat-execution-unknown-backend "Unknown execution backend")
(define-error 'chat-execution-renewal-required
  "Renewed permission is required before retry")

(cl-defstruct
    (chat-execution-request
     (:constructor chat-execution-request-create
                   (&key (schema-version chat-execution-schema-version)
                         id (backend 'local) command directory environment
                         session-id turn-id task-id parent-id
                         (idempotency 'non-idempotent) timeout metadata)))
  "One versioned backend-neutral execution request."
  schema-version id backend command directory environment
  session-id turn-id task-id parent-id idempotency timeout metadata)

(cl-defstruct
    (chat-execution-record
     (:constructor chat-execution-record-create
                   (&key (schema-version chat-execution-schema-version)
                         id request (status 'queued) attempts
                         created-at updated-at native-handle)))
  "Durable execution state plus an optional live backend handle."
  schema-version id request status attempts created-at updated-at native-handle)

(cl-defstruct
    (chat-execution-backend
     (:constructor chat-execution-backend-create
                   (&key id start-function cancel-function live-p-function)))
  "One backend implementation registered with the runtime."
  id start-function cancel-function live-p-function)

(defvar chat-execution--backends (make-hash-table :test 'eq)
  "Registered execution backends by symbol.")

(defvar chat-execution--records (make-hash-table :test 'equal)
  "Execution records by stable request ID.")

(defvar chat-execution--id-sequence 0
  "Process-local suffix for execution IDs created in one millisecond.")

(defvar chat-execution-current-context nil
  "Dynamically bound session, Turn, task and parent execution correlation.")

(cl-defun chat-execution-request-from-context
    (command &key id (backend 'local) directory environment
             session-id turn-id task-id parent-id
             (idempotency 'non-idempotent) timeout metadata)
  "Create an execution request for COMMAND using the current correlation.

Explicit identity arguments take precedence over the dynamically bound
`chat-execution-current-context'.  This is the common adapter entry point for
tool, task and extension processes; callers must still classify IDEMPOTENCY."
  (let ((context chat-execution-current-context))
    (chat-execution-request-create
     :id id
     :backend backend
     :command command
     :directory directory
     :environment environment
     :session-id (or session-id (plist-get context :session-id))
     :turn-id (or turn-id (plist-get context :turn-id))
     :task-id (or task-id (plist-get context :task-id))
     :parent-id (or parent-id (plist-get context :parent-id))
     :idempotency idempotency
     :timeout timeout
     :metadata metadata)))

(defun chat-execution--timestamp-ms ()
  "Return the current Unix time in milliseconds."
  (round (* 1000 (float-time))))

(defun chat-execution-new-id ()
  "Return a fresh execution request ID."
  (format "execution-%d-%d"
          (chat-execution--timestamp-ms)
          (cl-incf chat-execution--id-sequence)))

(defun chat-execution--symbol (value &optional fallback)
  "Return VALUE as a symbol, or FALLBACK when VALUE is empty."
  (cond ((symbolp value) value)
        ((and (stringp value) (not (string-empty-p value))) (intern value))
        (t fallback)))

(defun chat-execution--validate-request (request)
  "Validate and return REQUEST."
  (unless (chat-execution-request-p request)
    (signal 'chat-execution-invalid-request (list request)))
  (let ((version (chat-execution-request-schema-version request))
        (backend (chat-execution--symbol
                  (chat-execution-request-backend request) 'local))
        (idempotency (chat-execution--symbol
                      (chat-execution-request-idempotency request))))
    (unless (and (integerp version)
                 (= version chat-execution-schema-version))
      (signal 'chat-execution-invalid-request
              (list "schemaVersion" version)))
    (unless (and (listp (chat-execution-request-command request))
                 (chat-execution-request-command request)
                 (cl-every #'stringp
                           (chat-execution-request-command request)))
      (signal 'chat-execution-invalid-request
              (list "command must be a nonempty argv list")))
    (unless (memq idempotency chat-execution-idempotency-classes)
      (signal 'chat-execution-invalid-request
              (list "idempotency" idempotency)))
    (unless (or (null (chat-execution-request-directory request))
                (stringp (chat-execution-request-directory request)))
      (signal 'chat-execution-invalid-request
              (list "directory" (chat-execution-request-directory request))))
    (unless (or (null (chat-execution-request-timeout request))
                (and (numberp (chat-execution-request-timeout request))
                     (> (chat-execution-request-timeout request) 0)))
      (signal 'chat-execution-invalid-request
              (list "timeout" (chat-execution-request-timeout request))))
    (setf (chat-execution-request-backend request) backend
          (chat-execution-request-idempotency request) idempotency)
    (unless (chat-execution-request-id request)
      (setf (chat-execution-request-id request) (chat-execution-new-id)))
    request))

(defun chat-execution-register-backend (backend)
  "Register BACKEND and return it."
  (unless (and (chat-execution-backend-p backend)
               (symbolp (chat-execution-backend-id backend))
               (functionp (chat-execution-backend-start-function backend)))
    (error "Invalid execution backend: %S" backend))
  (puthash (chat-execution-backend-id backend)
           backend chat-execution--backends)
  backend)

(defun chat-execution-get-backend (id)
  "Return registered backend ID or signal explicitly."
  (or (gethash id chat-execution--backends)
      (signal 'chat-execution-unknown-backend (list id))))

(defun chat-execution--environment-keys (environment)
  "Return variable names from process ENVIRONMENT without their values."
  (delete-dups
   (delq nil
         (mapcar (lambda (entry)
                   (and (stringp entry)
                        (car (split-string entry "=" t))))
                 environment))))

(defun chat-execution--request-to-json (request)
  "Return durable JSON-friendly data for REQUEST."
  `((schemaVersion . ,(chat-execution-request-schema-version request))
    (id . ,(chat-execution-request-id request))
    (backend . ,(symbol-name (chat-execution-request-backend request)))
    (command . ,(chat-execution-request-command request))
    (directory . ,(chat-execution-request-directory request))
    (environmentKeys . ,(chat-execution--environment-keys
                          (chat-execution-request-environment request)))
    (sessionId . ,(chat-execution-request-session-id request))
    (turnId . ,(chat-execution-request-turn-id request))
    (taskId . ,(chat-execution-request-task-id request))
    (parentId . ,(chat-execution-request-parent-id request))
    (idempotency . ,(symbol-name
                     (chat-execution-request-idempotency request)))
    (timeout . ,(chat-execution-request-timeout request))
    (metadata . ,(chat-execution-request-metadata request))))

(defun chat-execution--request-from-json (data)
  "Return an execution request decoded from DATA."
  (chat-execution--validate-request
   (chat-execution-request-create
    :schema-version (or (alist-get 'schemaVersion data) 0)
    :id (alist-get 'id data)
    :backend (chat-execution--symbol (alist-get 'backend data) 'local)
    :command (append (alist-get 'command data) nil)
    :directory (alist-get 'directory data)
    ;; Values are deliberately not durable.  A retry uses the caller's
    ;; current environment unless it supplies fresh overrides.
    :environment nil
    :session-id (alist-get 'sessionId data)
    :turn-id (alist-get 'turnId data)
    :task-id (alist-get 'taskId data)
    :parent-id (alist-get 'parentId data)
    :idempotency (chat-execution--symbol
                  (alist-get 'idempotency data) 'non-idempotent)
    :timeout (alist-get 'timeout data)
    :metadata (alist-get 'metadata data))))

(defun chat-execution--attempt-to-json (attempt)
  "Return durable JSON-friendly data for ATTEMPT."
  `((number . ,(plist-get attempt :number))
    (status . ,(symbol-name (plist-get attempt :status)))
    (startedAt . ,(plist-get attempt :started-at))
    (endedAt . ,(plist-get attempt :ended-at))
    (exitCode . ,(plist-get attempt :exit-code))
    (reason . ,(plist-get attempt :reason))))

(defun chat-execution--attempt-from-json (data)
  "Return an attempt plist decoded from DATA."
  (list :number (alist-get 'number data)
        :status (chat-execution--symbol (alist-get 'status data) 'interrupted)
        :started-at (alist-get 'startedAt data)
        :ended-at (alist-get 'endedAt data)
        :exit-code (alist-get 'exitCode data)
        :reason (alist-get 'reason data)))

(defun chat-execution--record-to-json (record)
  "Return durable JSON-friendly data for RECORD."
  `((schemaVersion . ,(chat-execution-record-schema-version record))
    (id . ,(chat-execution-record-id record))
    (status . ,(symbol-name (chat-execution-record-status record)))
    (createdAt . ,(chat-execution-record-created-at record))
    (updatedAt . ,(chat-execution-record-updated-at record))
    (request . ,(chat-execution--request-to-json
                  (chat-execution-record-request record)))
    (attempts . ,(mapcar #'chat-execution--attempt-to-json
                         (chat-execution-record-attempts record)))))

(defun chat-execution--record-from-json (data)
  "Return an execution record decoded from DATA."
  (let ((version (or (alist-get 'schemaVersion data) 0)))
    (unless (= version chat-execution-schema-version)
      (error "Unsupported execution record schema version: %s" version))
    (chat-execution-record-create
     :schema-version version
     :id (alist-get 'id data)
     :request (chat-execution--request-from-json (alist-get 'request data))
     :status (chat-execution--symbol (alist-get 'status data) 'interrupted)
     :attempts (mapcar #'chat-execution--attempt-from-json
                       (alist-get 'attempts data))
     :created-at (alist-get 'createdAt data)
     :updated-at (alist-get 'updatedAt data))))

(defun chat-execution--state-file ()
  "Return the durable execution state file."
  (expand-file-name "records.json" chat-execution-directory))

(defun chat-execution-save ()
  "Atomically persist all execution records."
  (make-directory chat-execution-directory t)
  (let* ((target (chat-execution--state-file))
         (temp (make-temp-file
                (expand-file-name ".executions-" chat-execution-directory)))
         records)
    (unwind-protect
        (progn
          (maphash (lambda (_id record) (push record records))
                   chat-execution--records)
          (setq records
                (sort records
                      (lambda (left right)
                        (string< (chat-execution-record-id left)
                                 (chat-execution-record-id right)))))
          (with-temp-file temp
            (insert
             (json-encode
              `((schemaVersion . ,chat-execution-schema-version)
                (records . ,(mapcar #'chat-execution--record-to-json
                                    records))))))
          (rename-file temp target t))
      (when (file-exists-p temp)
        (delete-file temp))))
  t)

(defun chat-execution--maybe-save ()
  "Persist execution records when automatic saving is enabled."
  (when chat-execution-auto-save
    (chat-execution-save)))

(defun chat-execution--event (record type &optional attempt reason)
  "Publish TYPE for RECORD, ATTEMPT and optional REASON."
  (let* ((request (chat-execution-record-request record))
         (command (chat-execution-request-command request)))
    (chat-event-emit
     type
     :session-id (chat-execution-request-session-id request)
     :turn-id (chat-execution-request-turn-id request)
     :task-id (chat-execution-request-task-id request)
     :parent-id (chat-execution-request-parent-id request)
     :source 'execution
     :payload
     (delq nil
           (list (cons 'execution_id (chat-execution-record-id record))
                 (cons 'backend
                       (symbol-name (chat-execution-request-backend request)))
                 (cons 'attempt (and attempt (plist-get attempt :number)))
                 (cons 'status
                       (symbol-name (chat-execution-record-status record)))
                 (cons 'program (car command))
                 (cons 'argument_count (max 0 (1- (length command))))
                 (cons 'idempotency
                       (symbol-name
                        (chat-execution-request-idempotency request)))
                 (and reason
                      (cons 'reason
                            (truncate-string-to-width
                             (format "%s" reason) 512 nil nil t))))))))

(defun chat-execution--last-attempt (record)
  "Return RECORD's latest attempt plist."
  (car (last (chat-execution-record-attempts record))))

(defun chat-execution--set-last-attempt (record attempt)
  "Replace RECORD's latest attempt with ATTEMPT."
  (let ((attempts (chat-execution-record-attempts record)))
    (setf (chat-execution-record-attempts record)
          (append (butlast attempts) (list attempt)))))

(defun chat-execution--finish (record status &optional exit-code reason)
  "Finish RECORD once with STATUS, EXIT-CODE and REASON."
  (when (eq (chat-execution-record-status record) 'running)
    (let ((attempt (copy-sequence (chat-execution--last-attempt record)))
          (now (chat-execution--timestamp-ms)))
      (setq attempt (plist-put attempt :status status))
      (setq attempt (plist-put attempt :ended-at now))
      (setq attempt (plist-put attempt :exit-code exit-code))
      (setq attempt (plist-put attempt :reason reason))
      (chat-execution--set-last-attempt record attempt)
      (setf (chat-execution-record-status record) status
            (chat-execution-record-updated-at record) now
            (chat-execution-record-native-handle record) nil)
      (chat-execution--maybe-save)
      (chat-execution--event record 'execution-ended attempt reason)))
  record)

(defun chat-execution--local-start (request options sentinel)
  "Start local REQUEST with process OPTIONS and wrapped SENTINEL."
  (let ((default-directory
         (file-name-as-directory
          (or (chat-execution-request-directory request)
              default-directory)))
        (process-environment
         (or (chat-execution-request-environment request)
             process-environment)))
    (make-process
     :name (or (plist-get options :name)
               (chat-execution-request-id request))
     :buffer (plist-get options :buffer)
     :command (chat-execution-request-command request)
     :stderr (plist-get options :stderr)
     :noquery (if (plist-member options :noquery)
                  (plist-get options :noquery)
                t)
     :connection-type (or (plist-get options :connection-type) 'pipe)
     :coding (plist-get options :coding)
     :filter (plist-get options :filter)
     :sentinel sentinel)))

(defun chat-execution--local-cancel (native)
  "Cancel local NATIVE process."
  (when (and (processp native) (process-live-p native))
    (delete-process native)))

(defun chat-execution--local-live-p (native)
  "Return non-nil when local NATIVE process is alive."
  (and (processp native) (process-live-p native)))

(defun chat-execution-install-local-backend ()
  "Install the built-in local process backend."
  (chat-execution-register-backend
   (chat-execution-backend-create
    :id 'local
    :start-function #'chat-execution--local-start
    :cancel-function #'chat-execution--local-cancel
    :live-p-function #'chat-execution--local-live-p)))

(defun chat-execution--start-record (record options)
  "Start a new attempt for RECORD with transient process OPTIONS."
  (let* ((request (chat-execution-record-request record))
         (backend (chat-execution-get-backend
                   (chat-execution-request-backend request)))
         (attempt-number (1+ (length (chat-execution-record-attempts record))))
         (attempt (list :number attempt-number
                        :status 'running
                        :started-at (chat-execution--timestamp-ms)))
         (user-sentinel (plist-get options :sentinel))
         native)
    (setf (chat-execution-record-status record) 'running
          (chat-execution-record-updated-at record)
          (chat-execution--timestamp-ms)
          (chat-execution-record-attempts record)
          (append (chat-execution-record-attempts record) (list attempt)))
    (puthash (chat-execution-record-id record) record chat-execution--records)
    (chat-execution--maybe-save)
    (condition-case err
        (progn
          (setq native
                (funcall
                 (chat-execution-backend-start-function backend)
                 request options
                 (lambda (process event)
                   (unless (process-live-p process)
                     (chat-execution--finish
                      record
                      (if (zerop (process-exit-status process))
                          'completed
                        'failed)
                      (process-exit-status process)
                      (unless (zerop (process-exit-status process)) event)))
                   (when user-sentinel
                     (funcall user-sentinel process event)))))
          (setf (chat-execution-record-native-handle record) native)
          (when (processp native)
            (process-put native 'chat-execution-record record))
          (chat-execution--event record 'execution-started attempt)
          record)
      (error
       (chat-execution--finish record 'failed nil (error-message-string err))
       (signal (car err) (cdr err))))))

(cl-defun chat-execution-start (request &rest options)
  "Start REQUEST through its backend with transient process OPTIONS.

Supported OPTIONS mirror the local process needs: :name, :buffer, :stderr,
:filter, :sentinel, :connection-type, :coding and :noquery.  They are not
persisted.  Return a backend-neutral `chat-execution-record'."
  (chat-execution--validate-request request)
  (let* ((id (chat-execution-request-id request))
         (existing (gethash id chat-execution--records)))
    (when existing
      (error "Execution request already exists: %s" id))
    (let ((now (chat-execution--timestamp-ms))
          (record (chat-execution-record-create
                   :id id :request request :status 'queued)))
      (setf (chat-execution-record-created-at record) now
            (chat-execution-record-updated-at record) now)
      (chat-execution--start-record record options))))

(defun chat-execution-get (id)
  "Return execution record ID, or nil."
  (gethash id chat-execution--records))

(defun chat-execution-list ()
  "Return execution records ordered by creation time."
  (let (records)
    (maphash (lambda (_id record) (push record records))
             chat-execution--records)
    (sort records
          (lambda (left right)
            (< (or (chat-execution-record-created-at left) 0)
               (or (chat-execution-record-created-at right) 0))))))

(defun chat-execution-native-handle (record-or-id)
  "Return live native handle for RECORD-OR-ID, or nil."
  (let ((record (if (chat-execution-record-p record-or-id)
                    record-or-id
                  (chat-execution-get record-or-id))))
    (and record (chat-execution-record-native-handle record))))

(defun chat-execution-record-for-native (native)
  "Return the execution record attached to local NATIVE process."
  (and (processp native) (process-get native 'chat-execution-record)))

(defun chat-execution-live-p (record-or-id)
  "Return non-nil when RECORD-OR-ID has a live backend handle."
  (let* ((record (if (chat-execution-record-p record-or-id)
                     record-or-id
                   (chat-execution-get record-or-id)))
         (request (and record (chat-execution-record-request record)))
         (native (and record (chat-execution-record-native-handle record))))
    (and record
         (eq (chat-execution-record-status record) 'running)
         native
         (funcall
          (chat-execution-backend-live-p-function
           (chat-execution-get-backend
            (chat-execution-request-backend request)))
          native))))

(defun chat-execution-cancel (record-or-id &optional reason)
  "Cancel RECORD-OR-ID and durably record optional REASON."
  (let* ((record (if (chat-execution-record-p record-or-id)
                     record-or-id
                   (chat-execution-get record-or-id)))
         (request (and record (chat-execution-record-request record))))
    (unless record
      (error "Unknown execution record: %s" record-or-id))
    (let ((native (chat-execution-record-native-handle record))
          (backend (chat-execution-get-backend
                    (chat-execution-request-backend request))))
      ;; Close the durable attempt before deleting the process.  A local
      ;; sentinel may run synchronously during `delete-process'; seeing the
      ;; terminal record keeps it from racing cancellation into `failed'.
      (chat-execution--finish record 'canceled nil (or reason "cancelled"))
      (when (and native
                 (funcall (chat-execution-backend-live-p-function backend)
                          native))
        (funcall (chat-execution-backend-cancel-function backend) native)))
    record))

(cl-defun chat-execution-retry
    (record-or-id &key renewed-permission environment options)
  "Explicitly retry RECORD-OR-ID.

RENEWED-PERMISSION must be non-nil for a non-idempotent request.  ENVIRONMENT
supplies fresh process values because secret values are not persisted.  OPTIONS
contains the transient start options accepted by `chat-execution-start'."
  (let* ((record (if (chat-execution-record-p record-or-id)
                     record-or-id
                   (chat-execution-get record-or-id)))
         (request (and record (chat-execution-record-request record))))
    (unless record
      (error "Unknown execution record: %s" record-or-id))
    (when (chat-execution-live-p record)
      (error "Execution is already running: %s"
             (chat-execution-record-id record)))
    (when (and (eq (chat-execution-request-idempotency request)
                   'non-idempotent)
               (not renewed-permission))
      (chat-execution--event record 'execution-retry-refused nil
                             "renewed permission required")
      (signal 'chat-execution-renewal-required
              (list (chat-execution-record-id record))))
    (setf (chat-execution-request-environment request) environment)
    (chat-execution--start-record record options)))

(defun chat-execution-load ()
  "Load execution records and interrupt stale attempts without restarting."
  (clrhash chat-execution--records)
  (let ((file (chat-execution--state-file))
        interrupted)
    (when (file-exists-p file)
      (let* ((json-array-type 'list)
             (data (with-temp-buffer
                     (insert-file-contents file)
                     (json-read-from-string (buffer-string))))
             (version (or (alist-get 'schemaVersion data) 0)))
        (unless (= version chat-execution-schema-version)
          (error "Unsupported execution state schema version: %s" version))
        (dolist (entry (alist-get 'records data))
          (let ((record (chat-execution--record-from-json entry)))
            (when (eq (chat-execution-record-status record) 'running)
              (let ((attempt (copy-sequence
                              (chat-execution--last-attempt record)))
                    (now (chat-execution--timestamp-ms)))
                (setq attempt (plist-put attempt :status 'interrupted))
                (setq attempt (plist-put attempt :ended-at now))
                (setq attempt (plist-put attempt :reason "runtime restarted"))
                (chat-execution--set-last-attempt record attempt)
                (setf (chat-execution-record-status record) 'interrupted
                      (chat-execution-record-updated-at record) now)
                (push (cons record attempt) interrupted)))
            (puthash (chat-execution-record-id record)
                     record chat-execution--records)))))
    (when interrupted
      (chat-execution-save)
      (dolist (entry interrupted)
        (chat-execution--event (car entry) 'execution-interrupted
                               (cdr entry) "runtime restarted"))))
  (hash-table-count chat-execution--records))

(defun chat-execution-initialize ()
  "Install the local backend and reconcile durable execution state."
  (chat-execution-install-local-backend)
  (chat-execution-load))

(provide 'chat-execution)
;;; chat-execution.el ends here
