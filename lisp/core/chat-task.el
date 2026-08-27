;;; chat-task.el --- Durable task contract and scheduler -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;;; Commentary:

;; One durable task contract for foreground runs, background processes,
;; workflows, and delegated work.  Live runners and cancellation callbacks
;; are adapters; only intent, state, relationships, and bounded outcomes are
;; persisted.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'chat-event)
(require 'chat-session)

(defgroup chat-task nil
  "Durable runtime tasks."
  :group 'chat)

(defconst chat-task-schema-version 1
  "Current durable task schema version.")

(defconst chat-task-statuses
  '(queued running waiting-approval needs-attention
    completed failed canceled interrupted)
  "Canonical task states.")

(defconst chat-task-terminal-statuses
  '(completed failed canceled interrupted)
  "States that a task cannot leave.")

(defconst chat-task--transition-table
  '((queued . (running needs-attention canceled interrupted))
    (running . (waiting-approval needs-attention completed failed
                canceled interrupted))
    (waiting-approval . (queued running canceled interrupted))
    (needs-attention . (queued running failed canceled interrupted)))
  "Allowed non-idempotent task state transitions.")

(defcustom chat-task-directory (expand-file-name "~/.chat/tasks/")
  "Directory containing the durable task registry."
  :type 'directory
  :group 'chat-task)

(defcustom chat-task-max-parallel 4
  "Maximum number of scheduler-owned tasks running at once."
  :type 'integer
  :group 'chat-task)

(defcustom chat-task-auto-save t
  "Whether task mutations atomically update the durable registry."
  :type 'boolean
  :group 'chat-task)

(defcustom chat-task-event-text-limit 1024
  "Maximum task title, result, or error text retained in lifecycle events."
  :type 'integer
  :group 'chat-task)

(define-error 'chat-task-unsupported-schema "Unsupported task schema")
(define-error 'chat-task-invalid-transition "Invalid task state transition")
(define-error 'chat-task-terminal-conflict "Task already reached a terminal state")
(define-error 'chat-task-parent-missing "Task parent does not exist")

(cl-defstruct (chat-cancellation-token
               (:constructor chat-cancellation-token-create
                             (&key id canceled-p reason callbacks)))
  "One idempotent live cancellation token."
  id canceled-p reason callbacks)

(cl-defstruct
    (chat-task
     (:constructor
      chat-task-create
      (&key (schema-version chat-task-schema-version)
            id parent-id kind title (status 'queued) session-id source
            created-at updated-at started-at ended-at (attempt 0)
            (priority 0) resources payload result error checkpoint metadata
            (child-policy 'cancel) child-ids runner cancel-function
            cancellation-token terminal-event-p)))
  "One durable task plus optional live adapter fields."
  schema-version id parent-id kind title status session-id source
  created-at updated-at started-at ended-at attempt priority resources payload
  result error checkpoint metadata child-policy child-ids
  ;; Live fields below this point are never serialized.
  runner cancel-function cancellation-token terminal-event-p)

(defvar chat-task--registry (make-hash-table :test 'equal)
  "All known tasks keyed by stable id.")

(defvar chat-task--loaded-p nil
  "Whether the durable registry has been loaded in this Emacs process.")

(defvar chat-task--scheduling-p nil
  "Non-nil while the scheduler is selecting runnable work.")

(defun chat-task--timestamp ()
  "Return an RFC3339-like local timestamp."
  (format-time-string "%Y-%m-%dT%H:%M:%S%z" (current-time)))

(defun chat-task--new-id ()
  "Return a fresh task id."
  (chat-session-new-message-id "runtime-task"))

(defun chat-task--state-file ()
  "Return the durable task registry path."
  (expand-file-name "tasks.json" chat-task-directory))

(defun chat-task-terminal-p (task-or-status)
  "Return non-nil when TASK-OR-STATUS is terminal."
  (memq (if (chat-task-p task-or-status)
            (chat-task-status task-or-status)
          task-or-status)
        chat-task-terminal-statuses))

(defun chat-task-normalize-status (status)
  "Return canonical task STATUS, accepting compatibility names."
  (let ((status (if (stringp status) (intern status) status)))
    (or (cdr (assq status
                   '((pending . queued)
                     (active . running)
                     (succeeded . completed)
                     (success . completed)
                     (cancelled . canceled)
                     (awaiting-approval . waiting-approval)
                     (paused . needs-attention)
                     (stopped . completed)
                     (error . failed))))
        status)))

(defun chat-task--validate-resource (resource)
  "Validate and return RESOURCE."
  (let ((key (or (plist-get resource :key)
                 (alist-get 'key resource)))
        (mode (or (plist-get resource :mode)
                  (alist-get 'mode resource))))
    (unless (and (stringp key) (not (string-empty-p key))
                 (memq mode '(read write)))
      (error "Invalid task resource: %S" resource)))
  resource)

(defun chat-task--validate (task)
  "Validate and normalize TASK."
  (unless (chat-task-p task)
    (error "Not a task: %S" task))
  (let ((version (chat-task-schema-version task)))
    (when (> version chat-task-schema-version)
      (signal 'chat-task-unsupported-schema (list version)))
    (unless (= version chat-task-schema-version)
      (error "Task schema must be %d" chat-task-schema-version)))
  (unless (and (stringp (chat-task-id task))
               (not (string-empty-p (chat-task-id task))))
    (error "Task id must be non-empty text"))
  (setf (chat-task-status task)
        (chat-task-normalize-status (chat-task-status task)))
  (unless (memq (chat-task-status task) chat-task-statuses)
    (error "Unknown task status: %S" (chat-task-status task)))
  (unless (or (null (chat-task-parent-id task))
              (stringp (chat-task-parent-id task)))
    (error "Task parent id must be text or nil"))
  (unless (symbolp (chat-task-kind task))
    (error "Task kind must be a symbol"))
  (unless (or (null (chat-task-title task))
              (stringp (chat-task-title task)))
    (error "Task title must be text or nil"))
  (unless (numberp (chat-task-priority task))
    (error "Task priority must be numeric"))
  (unless (memq (chat-task-child-policy task) '(cancel detach wait))
    (error "Task child policy must be cancel, detach, or wait"))
  (mapc #'chat-task--validate-resource (chat-task-resources task))
  task)

(defun chat-cancellation-token-add-callback (token function)
  "Arrange for FUNCTION to run once when TOKEN is canceled."
  (unless (functionp function)
    (error "Cancellation callback must be callable"))
  (if (chat-cancellation-token-canceled-p token)
      (funcall function (chat-cancellation-token-reason token))
    (setf (chat-cancellation-token-callbacks token)
          (append (chat-cancellation-token-callbacks token)
                  (list function))))
  function)

(defun chat-cancellation-token-cancel (token &optional reason)
  "Cancel TOKEN once with optional REASON."
  (unless (chat-cancellation-token-canceled-p token)
    (setf (chat-cancellation-token-canceled-p token) t
          (chat-cancellation-token-reason token) reason)
    (let ((callbacks (chat-cancellation-token-callbacks token)))
      (setf (chat-cancellation-token-callbacks token) nil)
      (dolist (callback callbacks)
        (condition-case err
            (funcall callback reason)
          (error
           (message "Task cancellation callback failed: %s"
                    (error-message-string err)))))))
  token)

(defun chat-task--resource-key (resource)
  "Return RESOURCE's key."
  (or (plist-get resource :key) (alist-get 'key resource)))

(defun chat-task--resource-mode (resource)
  "Return RESOURCE's access mode."
  (or (plist-get resource :mode) (alist-get 'mode resource)))

(defun chat-task-resources-conflict-p (left right)
  "Return non-nil when task resources LEFT and RIGHT conflict."
  (seq-some
   (lambda (a)
     (seq-some
      (lambda (b)
        (and (equal (chat-task--resource-key a)
                    (chat-task--resource-key b))
             (or (eq (chat-task--resource-mode a) 'write)
                 (eq (chat-task--resource-mode b) 'write))))
      right))
   left))

(defun chat-task--event-text (value)
  "Return VALUE as bounded event text."
  (when value
    (truncate-string-to-width
     (if (stringp value) value (format "%S" value))
     chat-task-event-text-limit nil nil t)))

(defun chat-task--event-payload (task)
  "Return bounded lifecycle facts for TASK."
  (delq nil
        (list
         (cons 'kind (symbol-name (chat-task-kind task)))
         (cons 'status (symbol-name (chat-task-status task)))
         (when (chat-task-title task)
           (cons 'title (chat-task--event-text (chat-task-title task))))
         (cons 'attempt (chat-task-attempt task))
         (cons 'resource_count (length (chat-task-resources task)))
         (when (chat-task-result task)
           (cons 'result (chat-task--event-text (chat-task-result task))))
         (when (chat-task-error task)
           (cons 'error (chat-task--event-text (chat-task-error task)))))))

(defun chat-task--emit (task type)
  "Emit lifecycle TYPE for TASK."
  (chat-event-emit
   type
   :session-id (chat-task-session-id task)
   :task-id (chat-task-id task)
   :parent-id (chat-task-parent-id task)
   :source (or (chat-task-source task) 'task)
   :subject task
   :payload (chat-task--event-payload task)))

(defun chat-task--resource-to-json (resource)
  "Return RESOURCE as JSON-friendly data."
  `((key . ,(chat-task--resource-key resource))
    (mode . ,(symbol-name (chat-task--resource-mode resource)))))

(defun chat-task--to-json (task)
  "Return durable JSON-friendly data for TASK."
  `((schemaVersion . ,(chat-task-schema-version task))
    (id . ,(chat-task-id task))
    (parentId . ,(chat-task-parent-id task))
    (kind . ,(symbol-name (chat-task-kind task)))
    (title . ,(chat-task-title task))
    (status . ,(symbol-name (chat-task-status task)))
    (sessionId . ,(chat-task-session-id task))
    (source . ,(and (chat-task-source task)
                    (symbol-name (chat-task-source task))))
    (createdAt . ,(chat-task-created-at task))
    (updatedAt . ,(chat-task-updated-at task))
    (startedAt . ,(chat-task-started-at task))
    (endedAt . ,(chat-task-ended-at task))
    (attempt . ,(chat-task-attempt task))
    (priority . ,(chat-task-priority task))
    (resources . ,(mapcar #'chat-task--resource-to-json
                          (chat-task-resources task)))
    (payload . ,(chat-task-payload task))
    (result . ,(chat-task-result task))
    (error . ,(chat-task-error task))
    (checkpoint . ,(chat-task-checkpoint task))
    (metadata . ,(chat-task-metadata task))
    (childPolicy . ,(symbol-name (chat-task-child-policy task)))))

(defun chat-task--json-symbol (value fallback)
  "Return VALUE as a symbol, or FALLBACK."
  (cond ((symbolp value) value)
        ((and (stringp value) (not (string-empty-p value))) (intern value))
        (t fallback)))

(defun chat-task--from-json (data)
  "Return a task parsed from JSON DATA."
  (let ((status (chat-task-normalize-status (alist-get 'status data))))
    (chat-task--validate
     (chat-task-create
      :schema-version (or (alist-get 'schemaVersion data) 0)
      :id (alist-get 'id data)
      :parent-id (alist-get 'parentId data)
      :kind (chat-task--json-symbol (alist-get 'kind data) 'unknown)
      :title (alist-get 'title data)
      :status (if (eq status 'running) 'interrupted status)
      :session-id (alist-get 'sessionId data)
      :source (chat-task--json-symbol (alist-get 'source data) nil)
      :created-at (alist-get 'createdAt data)
      :updated-at (alist-get 'updatedAt data)
      :started-at (alist-get 'startedAt data)
      :ended-at (if (eq status 'running)
                    (chat-task--timestamp)
                  (alist-get 'endedAt data))
      :attempt (or (alist-get 'attempt data) 0)
      :priority (or (alist-get 'priority data) 0)
      :resources
      (mapcar (lambda (resource)
                (list :key (alist-get 'key resource)
                      :mode (chat-task--json-symbol
                             (alist-get 'mode resource) 'write)))
              (alist-get 'resources data))
      :payload (alist-get 'payload data)
      :result (alist-get 'result data)
      :error (alist-get 'error data)
      :checkpoint (alist-get 'checkpoint data)
      :metadata (alist-get 'metadata data)
      :child-policy (chat-task--json-symbol
                     (alist-get 'childPolicy data) 'cancel)
      :cancellation-token
      (chat-cancellation-token-create :id (alist-get 'id data))
      :terminal-event-p (memq (if (eq status 'running) 'interrupted status)
                              chat-task-terminal-statuses)))))

(defun chat-task-save ()
  "Atomically persist all durable task state."
  (make-directory chat-task-directory t)
  (let* ((target (chat-task--state-file))
         (temp (make-temp-file
                (expand-file-name ".tasks-" chat-task-directory)))
         tasks)
    (unwind-protect
        (progn
          (maphash (lambda (_id task) (push task tasks)) chat-task--registry)
          (setq tasks
                (sort tasks (lambda (left right)
                              (string< (chat-task-id left)
                                       (chat-task-id right)))))
          (with-temp-file temp
            (insert
             (json-encode
              `((schemaVersion . ,chat-task-schema-version)
                (tasks . ,(mapcar #'chat-task--to-json tasks))))))
          (rename-file temp target t))
      (when (file-exists-p temp)
        (delete-file temp))))
  t)

(defun chat-task--maybe-save ()
  "Persist tasks when automatic saving is enabled."
  (when chat-task-auto-save
    (chat-task-save)))

(defun chat-task--rebuild-children ()
  "Rebuild child indexes from parent ids."
  (maphash (lambda (_id task) (setf (chat-task-child-ids task) nil))
           chat-task--registry)
  (maphash
   (lambda (_id task)
     (when-let* ((parent-id (chat-task-parent-id task))
                 (parent (gethash parent-id chat-task--registry)))
       (setf (chat-task-child-ids parent)
             (append (chat-task-child-ids parent)
                     (list (chat-task-id task))))))
   chat-task--registry))

(defun chat-task-load ()
  "Load durable tasks, marking stale running tasks interrupted."
  (clrhash chat-task--registry)
  (let ((file (chat-task--state-file))
        interrupted)
    (when (file-exists-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (let* ((data (json-parse-buffer
                      :object-type 'alist :array-type 'list
                      :null-object nil :false-object :json-false))
               (version (or (alist-get 'schemaVersion data) 0)))
          (when (> version chat-task-schema-version)
            (signal 'chat-task-unsupported-schema (list version file)))
          (unless (= version chat-task-schema-version)
            (error "Task registry schema must be %d" chat-task-schema-version))
          (dolist (entry (alist-get 'tasks data))
            (when (eq (chat-task-normalize-status
                       (alist-get 'status entry))
                      'running)
              (setq interrupted t))
            (let ((task (chat-task--from-json entry)))
              (puthash (chat-task-id task) task chat-task--registry))))))
    (chat-task--rebuild-children)
    (setq chat-task--loaded-p t)
    (when (and interrupted chat-task-auto-save)
      (chat-task-save))
    (hash-table-count chat-task--registry)))

(defun chat-task-ensure-loaded ()
  "Load the durable registry once."
  (unless chat-task--loaded-p
    (chat-task-load)))

(defun chat-task-get (id)
  "Return task ID, or nil."
  (chat-task-ensure-loaded)
  (gethash id chat-task--registry))

(defun chat-task-register (task &optional replace)
  "Register TASK.  REPLACE permits replacing the same non-running id."
  (chat-task-ensure-loaded)
  (chat-task--validate task)
  (when (and (chat-task-parent-id task)
             (null (gethash (chat-task-parent-id task) chat-task--registry)))
    (signal 'chat-task-parent-missing (list (chat-task-parent-id task))))
  (let ((old (gethash (chat-task-id task) chat-task--registry)))
    (when (and old (not replace))
      (error "Task already exists: %s" (chat-task-id task)))
    (when (and old (eq (chat-task-status old) 'running))
      (error "Cannot replace running task: %s" (chat-task-id task))))
  (unless (chat-task-created-at task)
    (setf (chat-task-created-at task) (chat-task--timestamp)))
  (unless (chat-task-updated-at task)
    (setf (chat-task-updated-at task) (chat-task-created-at task)))
  (unless (chat-task-cancellation-token task)
    (setf (chat-task-cancellation-token task)
          (chat-cancellation-token-create :id (chat-task-id task))))
  (puthash (chat-task-id task) task chat-task--registry)
  (chat-task--rebuild-children)
  (chat-task--maybe-save)
  task)

(cl-defun chat-task-adopt
    (&key id parent-id kind title status session-id source priority resources
          payload result error checkpoint metadata child-policy runner
          cancel-function replace)
  "Register an adapter-owned task with explicit durable fields."
  (chat-task-register
   (chat-task-create
    :id (or id (chat-task--new-id)) :parent-id parent-id :kind kind
    :title title :status (or status 'queued) :session-id session-id
    :source source :priority (or priority 0) :resources resources
    :payload payload :result result :error error :checkpoint checkpoint
    :metadata metadata :child-policy (or child-policy 'cancel)
    :runner runner :cancel-function cancel-function
    :terminal-event-p (chat-task-terminal-p status))
   replace))

(defun chat-task--allowed-transition-p (from to)
  "Return non-nil when a task may move FROM to TO."
  (or (eq from to)
      (memq to (alist-get from chat-task--transition-table))))

(cl-defun chat-task-transition
    (task-or-id status
                &key ((:result result) nil result-supplied-p)
                ((:error error) nil error-supplied-p)
                ((:checkpoint checkpoint) nil checkpoint-supplied-p))
  "Move TASK-OR-ID to STATUS with optional durable outcome fields."
  (let* ((task (if (chat-task-p task-or-id)
                   task-or-id
                 (or (chat-task-get task-or-id)
                     (error "Task not found: %s" task-or-id))))
         (from (chat-task-status task))
         (to (chat-task-normalize-status status))
         (state-changed-p (not (eq from to)))
         (data-updated-p (or result-supplied-p error-supplied-p
                             checkpoint-supplied-p)))
    (unless (memq to chat-task-statuses)
      (error "Unknown task status: %S" to))
    (when (and (chat-task-terminal-p from) (not (eq from to)))
      (signal 'chat-task-terminal-conflict
              (list (chat-task-id task) from to)))
    (unless (chat-task--allowed-transition-p from to)
      (signal 'chat-task-invalid-transition
              (list (chat-task-id task) from to)))
    (when state-changed-p
      (setf (chat-task-status task) to
            (chat-task-updated-at task) (chat-task--timestamp))
      (when (eq to 'running)
        (setf (chat-task-started-at task)
              (or (chat-task-started-at task) (chat-task--timestamp))
              (chat-task-attempt task) (1+ (chat-task-attempt task))))
      (when (chat-task-terminal-p to)
        (setf (chat-task-ended-at task) (chat-task--timestamp))))
    (when result-supplied-p
      (setf (chat-task-result task) result))
    (when error-supplied-p
      (setf (chat-task-error task) error))
    (when (or checkpoint-supplied-p
              (memq to '(waiting-approval needs-attention)))
      (setf (chat-task-checkpoint task) checkpoint))
    (when (and data-updated-p (not state-changed-p))
      (setf (chat-task-updated-at task) (chat-task--timestamp)))
    (chat-task--maybe-save)
    (cond
     (state-changed-p
      (cond
       ((eq to 'running) (chat-task--emit task 'task-started))
       ((chat-task-terminal-p to)
        (unless (chat-task-terminal-event-p task)
          (setf (chat-task-terminal-event-p task) t)
          (chat-task--emit task 'task-ended)))
       (t (chat-task--emit task 'task-updated))))
     ((and data-updated-p (not (chat-task-terminal-p to)))
      (chat-task--emit task 'task-updated)))
    (when (and (chat-task-terminal-p to)
               (not chat-task--scheduling-p))
      (chat-task-schedule))
    task))

(defun chat-task-list (&optional session-id)
  "Return tasks in deterministic tree-friendly order.
When SESSION-ID is non-nil, return only tasks for that session."
  (chat-task-ensure-loaded)
  (let (tasks)
    (maphash
     (lambda (_id task)
       (when (or (null session-id)
                 (equal session-id (chat-task-session-id task)))
         (push task tasks)))
     chat-task--registry)
    (sort tasks
          (lambda (left right)
            (let ((lc (or (chat-task-created-at left) ""))
                  (rc (or (chat-task-created-at right) "")))
              (if (equal lc rc)
                  (string< (chat-task-id left) (chat-task-id right))
                (string< lc rc)))))))

(defun chat-task-children (task-or-id)
  "Return direct children of TASK-OR-ID."
  (let ((task (if (chat-task-p task-or-id)
                  task-or-id
                (chat-task-get task-or-id))))
    (mapcar #'chat-task-get (and task (chat-task-child-ids task)))))

(defun chat-task--running-tasks ()
  "Return currently running tasks."
  (seq-filter (lambda (task) (eq (chat-task-status task) 'running))
              (chat-task-list)))

(defun chat-task--queue-less-p (left right)
  "Return non-nil when LEFT should run before RIGHT."
  (if (= (chat-task-priority left) (chat-task-priority right))
      (string< (chat-task-id left) (chat-task-id right))
    (> (chat-task-priority left) (chat-task-priority right))))

(defun chat-task--runnable-p (task running)
  "Return non-nil when TASK may start beside RUNNING tasks."
  (and (eq (chat-task-status task) 'queued)
       (functionp (chat-task-runner task))
       (not (seq-some
             (lambda (active)
               (chat-task-resources-conflict-p
                (chat-task-resources task)
                (chat-task-resources active)))
             running))))

(defun chat-task--start (task)
  "Start scheduler-owned TASK through its live runner."
  (chat-task-transition task 'running :error nil :checkpoint nil)
  (let ((runner (chat-task-runner task)))
    (condition-case err
        (let ((value
               (funcall
                runner task
                (lambda (&optional result)
                  (when (eq (chat-task-status task) 'running)
                    (chat-task-transition task 'completed :result result)))
                (lambda (error)
                  (when (eq (chat-task-status task) 'running)
                    (chat-task-transition task 'failed :error error)))
                (lambda (status &optional checkpoint)
                  (when (eq (chat-task-status task) 'running)
                    (chat-task-transition
                     task
                     (if (eq status 'waiting-approval)
                         'waiting-approval
                       'needs-attention)
                     :checkpoint checkpoint))))))
          (unless (or (eq value :async)
                      (not (eq (chat-task-status task) 'running)))
            (chat-task-transition task 'completed :result value)))
      (error
       (when (eq (chat-task-status task) 'running)
         (chat-task-transition task 'failed
                               :error (error-message-string err)))))))

(defun chat-task-schedule ()
  "Start as many queued, non-conflicting tasks as the bound permits."
  (interactive)
  (unless chat-task--scheduling-p
    (let ((chat-task--scheduling-p t)
          (progress t))
      (while progress
        (setq progress nil)
        (let* ((running (chat-task--running-tasks))
               (capacity (- chat-task-max-parallel (length running)))
               (queued
                (sort
                 (seq-filter
                  (lambda (task) (eq (chat-task-status task) 'queued))
                  (chat-task-list))
                 #'chat-task--queue-less-p)))
          (when (> capacity 0)
            (while (and queued (> capacity 0))
              (let ((task (pop queued)))
                (when (chat-task--runnable-p task running)
                  (chat-task--start task)
                  (setq running (cons task running)
                        capacity (1- capacity)
                        progress t))))))))))

(defun chat-task-submit (task runner &optional cancel-function)
  "Register queued TASK with RUNNER and optional CANCEL-FUNCTION."
  (setf (chat-task-status task) 'queued
        (chat-task-runner task) runner
        (chat-task-cancel-function task) cancel-function)
  (chat-task-register task)
  (chat-task-schedule)
  task)

(defun chat-task-attach-adapter (id runner &optional cancel-function)
  "Attach live RUNNER and CANCEL-FUNCTION to durable task ID."
  (let ((task (or (chat-task-get id) (error "Task not found: %s" id))))
    (setf (chat-task-runner task) runner
          (chat-task-cancel-function task) cancel-function)
    task))

(defun chat-task-resume (id)
  "Queue recoverable task ID after its adapter has been attached."
  (let ((task (or (chat-task-get id) (error "Task not found: %s" id))))
    (unless (memq (chat-task-status task)
                  '(waiting-approval needs-attention))
      (error "Task is not waiting for attention: %s" id))
    (unless (functionp (chat-task-runner task))
      (error "Task adapter is not attached: %s" id))
    (chat-task-transition task 'queued :checkpoint nil :error nil)
    (chat-task-schedule)
    task))

(defun chat-task--active-children (task)
  "Return non-terminal direct children of TASK."
  (seq-remove #'chat-task-terminal-p (chat-task-children task)))

(defun chat-task-cancel (id &optional reason)
  "Cancel task ID once, applying its explicit child policy."
  (let ((task (or (chat-task-get id) (error "Task not found: %s" id))))
    (if (chat-task-terminal-p task)
        task
      (let ((children (chat-task--active-children task)))
        (pcase (chat-task-child-policy task)
          ('cancel
           (dolist (child children)
             (chat-task-cancel (chat-task-id child) "parent canceled")))
          ('wait
           (when children
             (error "Task %s still has active children" id)))
          ('detach
           (dolist (child children)
             (setf (chat-task-parent-id child) nil))
           (chat-task--rebuild-children)))
        (chat-cancellation-token-cancel
         (chat-task-cancellation-token task) reason)
        (let (cancel-error)
          (when-let* ((cancel-function (chat-task-cancel-function task)))
            (condition-case err
                (funcall cancel-function task reason)
              (error
               (setq cancel-error (error-message-string err)))))
          (chat-task-transition task 'canceled
                                :error (or cancel-error reason)))))))

(defun chat-task-summary (task)
  "Return a bounded public summary for TASK."
  `((id . ,(chat-task-id task))
    (parentId . ,(chat-task-parent-id task))
    (kind . ,(symbol-name (chat-task-kind task)))
    (title . ,(chat-task-title task))
    (status . ,(symbol-name (chat-task-status task)))
    (sessionId . ,(chat-task-session-id task))
    (attempt . ,(chat-task-attempt task))
    (childCount . ,(length (chat-task-child-ids task)))
    (createdAt . ,(chat-task-created-at task))
    (updatedAt . ,(chat-task-updated-at task))))

(provide 'chat-task)
;;; chat-task.el ends here
