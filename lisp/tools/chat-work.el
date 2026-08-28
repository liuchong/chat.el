;;; chat-work.el --- Work orchestration services for chat.el -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: chat, tasks, workflows

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Background tasks, session-local work records, and resumable declarative
;; workflows.  Workflow steps call registered tools or pause at explicit
;; approval checkpoints; they never evaluate arbitrary Lisp.
;;
;; Background commands go through `chat-command-gate', the same decision
;; `shell_execute' uses.  They did not until recently, and the gap was not
;; a small one: this is the only tool that hands a model-supplied string
;; to `sh -c', so while `shell_execute' refused `git log' for not being on
;; a list, the identical command ran here unexamined.  A subagent session
;; is created with auto-approve on, so on that path there was no list and
;; no prompt either.  A strict gate beside an open window is not a
;; boundary, and the strict half only cost us the time spent going around
;; it.
;;
;; The policy here is not the same list as `shell_execute' -- this tool
;; exists to run shell lines, so `&&' and `|' are accepted and each
;; segment is checked -- but the decision is the same function, so there
;; is one place to read and one place to change.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'chat-command-gate)
(require 'chat-execution)
(require 'chat-event)
(require 'chat-goal)
(require 'chat-session)
(require 'chat-task)
(require 'chat-tool-caller)
(require 'chat-tool-forge)

(declare-function chat-approval-command-consent-p "chat-approval" ())

(defgroup chat-work nil
  "Work orchestration for chat.el."
  :group 'chat)

(defcustom chat-work-directory
  (expand-file-name "~/.chat/work/")
  "Directory where background task state and logs are stored."
  :type 'directory
  :group 'chat-work)

(defconst chat-work-task-schema-version 1
  "Version of the persisted background task document.")

(defcustom chat-work-task-output-max-chars 20000
  "Maximum background task output returned from one tool call."
  :type 'integer
  :group 'chat-work)

(defcustom chat-work-notify-task-completion t
  "Whether completed background tasks produce a desktop notification."
  :type 'boolean
  :group 'chat-work)

(defcustom chat-work-workflow-max-steps 100
  "Maximum number of steps accepted in one workflow."
  :type 'integer
  :group 'chat-work)

(defcustom chat-work-task-allowed-commands
  '("ls" "cat" "pwd" "echo" "printf" "head" "tail" "grep" "find" "wc" "which"
    "type" "du" "stat" "sort" "uniq" "cut" "sed" "awk" "tr" "git" "sleep"
    "true" "false" "test" "mkdir" "cd")
  "Programs a background task may run.

Deliberately close to `chat-tool-shell-allowed-commands' and deliberately
not open-ended.  A background task used to be `sh -c ANYTHING', which on
an auto-approved subagent session meant a model could run anything at all
with nothing between it and the shell.

Build and test runners are not here, because guessing which ones a
project uses would produce a list that is wrong for every project and
reassuring in all of them.  Add the ones this machine needs -- \"make\",
\"cargo\", \"npm\", \"pytest\" -- and the refusal names this variable when
something is missing, so the gap says how to close itself."
  :type '(repeat string)
  :group 'chat-work)

(defvar chat-work-task-finished-hook nil
  "Hook run with one argument, a finished `chat-work-task'.")

(cl-defstruct chat-work-task
  id
  session-id
  command
  directory
  status
  started-at
  ended-at
  exit-code
  log-file
  process)

(defvar chat-work--tasks (make-hash-table :test 'equal)
  "Known background tasks keyed by id.")

(defvar chat-work--global-state nil
  "Fallback work state when no session is active.")

(defvar chat-work--syncing-workflow-task nil
  "Non-nil while workflow and task adapters synchronize each other.")

(defun chat-work--ensure-directory ()
  "Ensure the work directory exists."
  (unless (file-directory-p chat-work-directory)
    (make-directory chat-work-directory t)))

(defun chat-work--state-file ()
  "Return the background task state file."
  (expand-file-name "tasks.json" chat-work-directory))

(defun chat-work--task-id ()
  "Return a fresh work task id."
  (chat-session-new-message-id "task"))

(defun chat-work--timestamp ()
  "Return the current timestamp string."
  (format-time-string "%Y-%m-%dT%H:%M:%S" (current-time)))

(defun chat-work--event-payload (task)
  "Return bounded lifecycle facts for TASK."
  (delq nil
        (list
         (cons 'status (format "%s" (chat-work-task-status task)))
         (cons 'command
               (truncate-string-to-width
                (or (chat-work-task-command task) "") 500 nil nil t))
         (cons 'directory (chat-work-task-directory task))
         (when (chat-work-task-exit-code task)
           (cons 'exit_code (chat-work-task-exit-code task))))))

(defun chat-work--emit-task-event (type task)
  "Publish lifecycle TYPE for TASK."
  (chat-event-emit
   type
   :session-id (chat-work-task-session-id task)
   :task-id (chat-work-task-id task)
   :source 'work
   :subject task
   :payload (chat-work--event-payload task)))

(defun chat-work--notify-task-finished (task)
  "Notify the user that TASK reached a terminal state."
  (run-hook-with-args 'chat-work-task-finished-hook task)
  (when chat-work-notify-task-completion
    (let ((title (format "Background task %s"
                         (symbol-name (chat-work-task-status task))))
          (body (format "%s\n%s"
                        (chat-work-task-id task)
                        (chat-work-task-command task))))
      (if (and (require 'notifications nil t)
               (fboundp 'notifications-notify))
          (notifications-notify :title title :body body
                                :app-name "chat.el")
        (message "%s: %s" title body)))))

(defun chat-work--task-to-json (task)
  "Convert TASK to JSON-friendly data."
  `((id . ,(chat-work-task-id task))
    (sessionId . ,(chat-work-task-session-id task))
    (command . ,(chat-work-task-command task))
    (directory . ,(chat-work-task-directory task))
    (status . ,(symbol-name (chat-work-task-status task)))
    (startedAt . ,(chat-work-task-started-at task))
    (endedAt . ,(chat-work-task-ended-at task))
    (exitCode . ,(chat-work-task-exit-code task))
    (logFile . ,(chat-work-task-log-file task))))

(defun chat-work--task-from-json (data)
  "Convert DATA to a task struct."
  (make-chat-work-task
   :id (cdr (assoc 'id data))
   :session-id (cdr (assoc 'sessionId data))
   :command (cdr (assoc 'command data))
   :directory (cdr (assoc 'directory data))
   :status (intern (or (cdr (assoc 'status data)) "unknown"))
   :started-at (cdr (assoc 'startedAt data))
   :ended-at (cdr (assoc 'endedAt data))
   :exit-code (cdr (assoc 'exitCode data))
   :log-file (cdr (assoc 'logFile data))))

(defun chat-work-save-tasks ()
  "Persist background task state."
  (chat-work--ensure-directory)
  (let (tasks)
    (maphash (lambda (_id task)
               (push (chat-work--task-to-json task) tasks))
             chat-work--tasks)
    (with-temp-file (chat-work--state-file)
      (insert
       (json-encode
        `((schemaVersion . ,chat-work-task-schema-version)
          (tasks . ,(vconcat (nreverse tasks)))))))))

(defun chat-work-load-tasks ()
  "Load background task state and mark stale running tasks interrupted."
  (chat-work--ensure-directory)
  (clrhash chat-work--tasks)
  (let ((file (chat-work--state-file))
        migrated)
    (when (file-exists-p file)
      (let* ((json-array-type 'list)
             (data (condition-case nil
                       (with-temp-buffer
                         (insert-file-contents file)
                         (json-read-from-string (buffer-string)))
                     (error nil)))
             (version (or (cdr (assoc 'schemaVersion data)) 0))
             (tasks (cdr (assoc 'tasks data))))
        (when (> version chat-work-task-schema-version)
          (error "Unsupported background task schema version: %s" version))
        (dolist (entry tasks)
          (let ((task (chat-work--task-from-json entry)))
            (when (eq (chat-work-task-status task) 'running)
              (setf (chat-work-task-status task) 'interrupted
                    (chat-work-task-ended-at task) (chat-work--timestamp)))
            (puthash (chat-work-task-id task) task chat-work--tasks)
            (unless (chat-task-get (chat-work-task-id task))
              (setq migrated t)
              (let ((chat-task-auto-save nil))
                (chat-task-adopt
                 :id (chat-work-task-id task)
                 :kind 'process
                 :title (chat-work-task-command task)
                 :status (chat-task-normalize-status
                          (chat-work-task-status task))
                 :session-id (chat-work-task-session-id task)
                 :source 'work
                 :resources
                 (list (list :key (concat "directory:"
                                          (chat-work-task-directory task))
                             :mode 'write))
                 :payload
                 `((command . ,(chat-work-task-command task))
                   (directory . ,(chat-work-task-directory task)))
                 :result (chat-work-task-exit-code task)))))))
      (when (and migrated chat-task-auto-save)
        (chat-task-save)))
  (hash-table-count chat-work--tasks)))

(defun chat-work-task-refusal (command)
  "Return why COMMAND may not run as a background task, or nil when it may.

Separators are allowed and each segment is checked, because a background
task is a shell line by construction -- `cd build && make' is the shape
this tool is for, and refusing it would be refusing the tool."
  (chat-command-gate-check command
                           :commands chat-work-task-allowed-commands
                           :separators t))

(defun chat-work--task-refusal-message (refusal command)
  "Return REFUSAL as the result text for background COMMAND."
  (concat
   (chat-command-gate-explain refusal command)
   (when (eq (chat-command-gate-refusal-code refusal) 'unknown-command)
     ". Add it to `chat-work-task-allowed-commands' if this machine needs it")))

(defun chat-work--runtime-resource (directory)
  "Return the scheduler resource for DIRECTORY."
  (list :key (concat "directory:"
                     (file-name-as-directory
                      (expand-file-name directory)))
        :mode 'write))

(defun chat-work--run-process-task (task _runtime-task complete fail)
  "Start process adapter TASK for RUNTIME-TASK and finish through callbacks."
  (let* ((id (chat-work-task-id task))
         (command (chat-work-task-command task))
         (log-file (chat-work-task-log-file task))
         (default-directory (chat-work-task-directory task))
         (process-environment (chat-command-gate-environment))
         process)
    (setf (chat-work-task-status task) 'running
          (chat-work-task-started-at task) (chat-work--timestamp))
    (condition-case err
        (progn
          (let ((record
                 (chat-execution-start
                 (chat-execution-request-from-context
                   (list shell-file-name shell-command-switch command)
                   :backend (chat-execution-backend-for-policy 'build)
                   :directory default-directory
                   :environment process-environment
                   :policy 'build
                   :read-roots (list default-directory)
                   :write-roots (list default-directory)
                   :network nil
                   :require-process-tree-cleanup t
                   :session-id (chat-work-task-session-id task)
                   :task-id id
                   :idempotency 'non-idempotent
                   :metadata '((kind . "background-task")))
                  :name (concat "chat-work-" id)
                  :buffer nil
                  :noquery t
                  :connection-type 'pipe
                  :filter (lambda (_proc chunk)
                            (write-region chunk nil log-file 'append 'silent))
                  :sentinel
                  (lambda (proc _event)
                    (unless (process-live-p proc)
                      (unless (eq (chat-work-task-status task) 'cancelled)
                        (let ((exit-code (process-exit-status proc)))
                          (setf (chat-work-task-status task)
                                (if (zerop exit-code) 'succeeded 'failed)
                                (chat-work-task-exit-code task) exit-code
                                (chat-work-task-ended-at task)
                                (chat-work--timestamp))
                          (chat-work-save-tasks)
                          (if (zerop exit-code)
                              (funcall complete `((exitCode . ,exit-code)
                                                  (logFile . ,log-file)))
                            (funcall fail
                                     (format "Process exited with %d"
                                             exit-code)))
                          (chat-work--notify-task-finished task))))))))
            (setq process (chat-execution-native-handle record)))
          (setf (chat-work-task-process task) process)
          (chat-work-save-tasks)
          :async)
      (error
       (setf (chat-work-task-status task) 'failed
             (chat-work-task-ended-at task) (chat-work--timestamp))
       (chat-work-save-tasks)
       (chat-work--notify-task-finished task)
       (signal (car err) (cdr err))))))

(defun chat-work--cancel-process-task (task _runtime-task reason)
  "Cancel process adapter TASK with REASON."
  (setf (chat-work-task-status task) 'cancelled
        (chat-work-task-ended-at task) (chat-work--timestamp))
  (when-let* ((process (chat-work-task-process task)))
    (when (process-live-p process)
      (if-let* ((record (chat-execution-record-for-native process)))
          (chat-execution-cancel record reason)
        (delete-process process))))
  (chat-work-save-tasks)
  (chat-work--notify-task-finished task)
  reason)

(defun chat-work-task-start (command &optional directory)
  "Start COMMAND as a cancellable background task in DIRECTORY.

Refuses before starting anything when the command does not pass
`chat-work-task-refusal', and says why.  A task that cannot run should
not appear in the task list as one that failed: the two look the same
afterwards and mean entirely different things.

The list is skipped when a person approved this command or dangerous mode
is on.  Build and test runners are what this tool is for, and they cannot
all be enumerated in advance -- `make', `cargo', `pytest', a project's own
script.  A user who reads `make test' and approves it has answered the
question the list exists to ask, and re-asking it in code only voids their
answer.  Under `auto' the list still decides, because there nobody read
anything."
  (unless (and (fboundp 'chat-approval-command-consent-p)
               (chat-approval-command-consent-p))
    (when-let* ((refusal (chat-work-task-refusal command)))
      (error "%s" (chat-work--task-refusal-message refusal command))))
  (chat-work--ensure-directory)
  (let* ((session (chat-work--current-session))
         (session-id (and session (chat-session-id session)))
         (id (chat-work--task-id))
         (task-directory (file-name-as-directory
                          (or directory default-directory)))
         (log-file (expand-file-name (concat id ".log") chat-work-directory))
         (task (make-chat-work-task
                :id id
                :session-id session-id
                :command command
                :directory task-directory
                :status 'queued
                :log-file log-file)))
    (with-temp-file log-file)
    (puthash id task chat-work--tasks)
    (chat-work-save-tasks)
    (let ((runtime-task
           (chat-task-create
            :id id :kind 'process :title command :session-id session-id
            :source 'work
            :resources (list (chat-work--runtime-resource task-directory))
            :payload `((command . ,command) (directory . ,task-directory)))))
      (chat-task-submit
       runtime-task
       (lambda (generic complete fail _attention)
         (chat-work--run-process-task task generic complete fail))
       (lambda (generic reason)
         (chat-work--cancel-process-task task generic reason))))
    (chat-work-task-summary task)))

(defun chat-work-task-summary (task)
  "Return a compact summary alist for TASK."
  `((id . ,(chat-work-task-id task))
    (command . ,(chat-work-task-command task))
    (status . ,(symbol-name (chat-work-task-status task)))
    (exitCode . ,(chat-work-task-exit-code task))
    (logFile . ,(chat-work-task-log-file task))))

(defun chat-work-task-list ()
  "Return summaries for known background tasks."
  (let (tasks)
    (maphash (lambda (_id task)
               (push (chat-work-task-summary task) tasks))
             chat-work--tasks)
    (nreverse tasks)))

(defun chat-work-task-output (id &optional max-chars)
  "Return bounded output for task ID."
  (let* ((task (gethash id chat-work--tasks))
         (limit (or max-chars chat-work-task-output-max-chars)))
    (unless task
      (error "Task not found: %s" id))
    (if (not (file-exists-p (chat-work-task-log-file task)))
        ""
      (with-temp-buffer
        (insert-file-contents (chat-work-task-log-file task))
        (let ((text (buffer-string)))
          (if (> (length text) limit)
              (concat (substring text (- (length text) limit))
                      "\n... [earlier output omitted]")
            text))))))

(defun chat-work-task-stop (id)
  "Stop running task ID."
  (let ((task (gethash id chat-work--tasks)))
    (unless task
      (error "Task not found: %s" id))
    (if (chat-task-get id)
        (chat-task-cancel id "stopped by user")
      (chat-work--cancel-process-task task nil "stopped by user"))
    (chat-work-task-summary task)))

(defun chat-work--current-session ()
  "Return the session currently executing a work tool, if any."
  (and (boundp 'chat-tool-caller-current-session)
       chat-tool-caller-current-session))

(defun chat-work--normalize-json (value)
  "Normalize decoded JSON VALUE into list-backed data."
  (cond
   ((vectorp value)
    (mapcar #'chat-work--normalize-json (append value nil)))
   ((consp value)
    (mapcar (lambda (entry)
              (if (consp entry)
                  (cons (car entry)
                        (chat-work--normalize-json (cdr entry)))
                (chat-work--normalize-json entry)))
            value))
   (t value)))

(defun chat-work--state ()
  "Return the current session-local work state."
  (let ((session (chat-work--current-session)))
    (if session
        (or (chat-work--normalize-json
             (cdr (assoc 'work (chat-session-metadata session))))
            '((plan . nil) (todos . nil) (goals . nil) (workflows . nil)))
      (or chat-work--global-state
          '((plan . nil) (todos . nil) (goals . nil) (workflows . nil))))))

(defun chat-work--set-state (state)
  "Persist STATE into the current session when available."
  (let ((session (chat-work--current-session)))
    (if session
        (let ((metadata (assq-delete-all 'work
                                         (copy-tree
                                          (chat-session-metadata session)))))
          (setf (chat-session-metadata session)
                (cons (cons 'work state) metadata))
          (setf (chat-session-updated-at session) (current-time))
          (when chat-session-auto-save
            (chat-session-save session)))
      (setq chat-work--global-state state))
    state))

(defun chat-work--state-get (state key)
  "Return KEY from work STATE."
  (cdr (assoc key state)))

(defun chat-work--state-put (state key value)
  "Return STATE with KEY set to VALUE."
  (cons (cons key value) (assq-delete-all key (copy-tree state))))

(defun chat-work-plan-enter (title)
  "Enter session-local plan mode with TITLE."
  (let* ((state (chat-work--state))
         (plan `((status . "active")
                 (title . ,title)
                 (updatedAt . ,(chat-work--timestamp)))))
    (chat-work--set-state (chat-work--state-put state 'plan plan))
    plan))

(defun chat-work-plan-exit ()
  "Exit session-local plan mode."
  (let* ((state (chat-work--state))
         (plan (or (chat-work--state-get state 'plan) nil))
         (updated (append '((status . "completed"))
                          (assq-delete-all 'status (copy-tree plan)))))
    (chat-work--set-state (chat-work--state-put state 'plan updated))
    updated))

(defun chat-work--record-add (collection title)
  "Add TITLE to COLLECTION in the current work state."
  (let* ((state (chat-work--state))
         (records (chat-work--state-get state collection))
         (record `((id . ,(chat-session-new-message-id
                           (symbol-name collection)))
                   (title . ,title)
                   (status . "pending")
                   (createdAt . ,(chat-work--timestamp)))))
    (chat-work--set-state
     (chat-work--state-put state collection (append records (list record))))
    record))

(defun chat-work--record-update (collection id status)
  "Set STATUS on record ID in COLLECTION."
  (let* ((state (chat-work--state))
         (records (chat-work--state-get state collection))
         found)
    (setq records
          (mapcar (lambda (record)
                    (if (equal (cdr (assoc 'id record)) id)
                        (progn
                          (setq found t)
                          (cons (cons 'status status)
                                (assq-delete-all 'status (copy-tree record))))
                      record))
                  records))
    (unless found
      (error "Record not found: %s" id))
    (chat-work--set-state (chat-work--state-put state collection records))
    (cl-find id records :key (lambda (record) (cdr (assoc 'id record)))
             :test #'equal)))

(defun chat-work-todo-add (title)
  "Add a session-local TODO with TITLE."
  (chat-work--record-add 'todos title))

(defun chat-work-todo-update (id status)
  "Update TODO ID to STATUS."
  (chat-work--record-update 'todos id status))

(defun chat-work-todo-list ()
  "List session-local TODO records."
  (chat-work--state-get (chat-work--state) 'todos))

(defun chat-work-goal-add (title)
  "Refuse legacy goal creation from incomplete TITLE."
  (ignore title)
  (error "work_goal_add is retired; use programming_goal_create with success criteria and a stopping condition"))

(defun chat-work-goal-update (id status)
  "Refuse legacy status mutation for ID and STATUS."
  (ignore id status)
  (error "work_goal_update is retired; use the revision-checked Goal lifecycle tools"))

(defun chat-work-goal-list ()
  "List durable Goal records through the canonical Goal store."
  (when-let ((session (chat-work--current-session)))
    (mapcar #'chat-goal-to-alist (chat-goal-list session))))

(defun chat-work--json-get (object key)
  "Return KEY from decoded JSON OBJECT with string or symbol keys."
  (or (cdr (assoc key object))
      (and (symbolp key) (cdr (assoc (symbol-name key) object)))
      (and (stringp key) (cdr (assoc (intern key) object)))))

(defun chat-work--alist-set (alist key value)
  "Return ALIST with KEY set to VALUE."
  (cons (cons key value) (assq-delete-all key (copy-tree alist))))

(defun chat-work--workflow-find (id)
  "Return workflow ID from current work state."
  (cl-find id (chat-work--state-get (chat-work--state) 'workflows)
           :key (lambda (workflow) (chat-work--json-get workflow 'id))
           :test #'equal))

(defun chat-work--session-parent-task-id (session)
  "Return SESSION's live parent task id when it still exists."
  (when session
    (let* ((metadata (chat-session-metadata session))
           (id (or (cdr (assoc 'activeTaskId metadata))
                   (cdr (assoc 'parentTaskId metadata)))))
      (when-let* ((task (and id (chat-task-get id))))
        (and (eq (chat-task-status task) 'running) id)))))

(defun chat-work--workflow-task-status (workflow)
  "Return canonical task status for WORKFLOW."
  (chat-task-normalize-status
   (or (chat-work--json-get workflow 'status) "paused")))

(defun chat-work--workflow-task-checkpoint (workflow)
  "Return a bounded durable checkpoint for WORKFLOW."
  (let ((status (chat-work--json-get workflow 'status))
        (index (or (chat-work--json-get workflow 'stepIndex) 0)))
    (cond
     ((equal status "awaiting-approval")
      (let ((step (nth index (chat-work--json-get workflow 'steps))))
        `((stepIndex . ,index)
          (kind . "approval")
          (message . ,(chat-work--json-get step 'message)))))
     ((equal status "paused")
      `((stepIndex . ,index)
        (error . ,(chat-work--json-get workflow 'error)))))))

(defun chat-work--cancel-workflow-task (session id reason)
  "Cancel workflow ID in SESSION because its runtime task was cancelled."
  (unless chat-work--syncing-workflow-task
    (let ((chat-tool-caller-current-session session)
          (chat-work--syncing-workflow-task t))
      (when-let* ((workflow (chat-work--workflow-find id)))
        (unless (member (chat-work--json-get workflow 'status)
                        '("completed" "cancelled"))
          (setq workflow
                (chat-work--alist-set
                 (chat-work--alist-set workflow 'status "cancelled")
                 'error reason))
          (chat-work--workflow-store workflow))))))

(defun chat-work--sync-workflow-task (workflow)
  "Mirror WORKFLOW into the durable runtime task registry."
  (unless chat-work--syncing-workflow-task
    (let* ((chat-work--syncing-workflow-task t)
           (session (chat-work--current-session))
           (id (chat-work--json-get workflow 'id))
           (status (chat-work--workflow-task-status workflow))
           (task (chat-task-get id))
           (cancel-function
            (lambda (_task reason)
              (chat-work--cancel-workflow-task session id reason))))
      (unless task
        (setq task
              (chat-task-adopt
               :id id
               :parent-id (chat-work--session-parent-task-id session)
               :kind 'workflow
               :title (chat-work--json-get workflow 'name)
               :status (if (eq status 'running) 'queued status)
               :session-id (and session (chat-session-id session))
               :source 'work
               :payload
               `((stepCount . ,(length
                                (chat-work--json-get workflow 'steps))))
               :metadata '((adapter . "session-workflow"))
               :child-policy 'cancel
               :cancel-function cancel-function)))
      (setf (chat-task-title task) (chat-work--json-get workflow 'name)
            (chat-task-session-id task)
            (and session (chat-session-id session))
            (chat-task-payload task)
            `((stepIndex . ,(or (chat-work--json-get workflow 'stepIndex) 0))
              (stepCount . ,(length
                             (chat-work--json-get workflow 'steps))))
            (chat-task-metadata task) '((adapter . "session-workflow"))
            (chat-task-cancel-function task) cancel-function)
      (chat-task-transition
       task status
       :result (chat-work--json-get workflow 'results)
       :error (chat-work--json-get workflow 'error)
       :checkpoint (chat-work--workflow-task-checkpoint workflow)))))

(defun chat-work--workflow-store (workflow)
  "Persist WORKFLOW and return it."
  (let* ((state (chat-work--state))
         (id (chat-work--json-get workflow 'id))
         (found nil)
         (workflows
          (mapcar
           (lambda (entry)
             (if (equal (chat-work--json-get entry 'id) id)
                 (progn (setq found t) workflow)
               entry))
           (chat-work--state-get state 'workflows))))
    (unless found
      (setq workflows (append workflows (list workflow))))
    (chat-work--set-state
     (chat-work--state-put state 'workflows workflows))
    (chat-work--sync-workflow-task workflow)
    workflow))

(defun chat-work--workflow-valid-step-p (step)
  "Return non-nil when STEP has a supported declarative shape."
  (let ((kind (chat-work--json-get step 'kind)))
    (cond
     ((equal kind "tool")
      (let ((name (chat-work--json-get step 'name))
            (arguments (chat-work--json-get step 'arguments)))
        (and (stringp name)
             (not (string-empty-p name))
             (not (member name '("work_workflow_start"
                                 "work_workflow_resume"
                                 "work_workflow_cancel")))
             (or (null arguments) (listp arguments)))))
     ((equal kind "approval")
      (stringp (chat-work--json-get step 'message)))
     (t nil))))

(defun chat-work--workflow-validate-steps (steps)
  "Validate declarative workflow STEPS or signal an error."
  (unless (listp steps)
    (error "Workflow steps must be a JSON array"))
  (when (> (length steps) chat-work-workflow-max-steps)
    (error "Workflow exceeds the %d step limit"
           chat-work-workflow-max-steps))
  (cl-loop for step in steps
           for index from 0
           unless (chat-work--workflow-valid-step-p step)
           do (error "Invalid workflow step %d" index))
  steps)

(defun chat-work--workflow-result (workflow index)
  "Return result at INDEX from WORKFLOW."
  (cl-find index (chat-work--json-get workflow 'results)
           :key (lambda (result)
                  (chat-work--json-get result 'stepIndex))
           :test #'equal))

(defun chat-work--workflow-condition-p (workflow condition)
  "Return non-nil when WORKFLOW satisfies declarative CONDITION.
CONDITION may compare a prior step's status or result text.  Supported
keys are `step', `status', `equals', `notEquals', and `contains'."
  (if (null condition)
      t
    (let* ((step-index (chat-work--json-get condition 'step))
           (prior (and (integerp step-index)
                       (chat-work--workflow-result workflow step-index)))
           (actual-status (and prior
                               (chat-work--json-get prior 'status)))
           (actual-result (and prior
                               (chat-work--json-get prior 'result)))
           (status (chat-work--json-get condition 'status))
           (equals (chat-work--json-get condition 'equals))
           (not-equals (chat-work--json-get condition 'notEquals))
           (contains (chat-work--json-get condition 'contains)))
      (and prior
           (or (null status) (equal actual-status status))
           (or (null equals) (equal actual-result equals))
           (or (null not-equals) (not (equal actual-result not-equals)))
           (or (null contains)
               (and (stringp actual-result)
                    (string-match-p (regexp-quote contains)
                                    actual-result)))))))

(defun chat-work--workflow-string-arguments (arguments)
  "Return ARGUMENTS with top-level keys converted to strings."
  (mapcar (lambda (entry)
            (cons (if (symbolp (car entry))
                      (symbol-name (car entry))
                    (car entry))
                  (cdr entry)))
          arguments))

(defun chat-work--workflow-record-result
    (workflow index status &optional result error)
  "Record INDEX STATUS and optional RESULT or ERROR in WORKFLOW."
  (let* ((record `((stepIndex . ,index)
                   (status . ,status)
                   (result . ,result)
                   (error . ,error)
                   (completedAt . ,(chat-work--timestamp))))
         (results (chat-work--json-get workflow 'results)))
    (chat-work--alist-set
     workflow 'results
     (append
      (cl-remove index results
                 :key (lambda (entry)
                        (chat-work--json-get entry 'stepIndex))
                 :test #'equal)
      (list record)))))

(defun chat-work--workflow-tool-error-result-p (result)
  "Return non-nil when RESULT is the tool caller's error envelope."
  (and (stringp result)
       (or (string-prefix-p "Error:" result)
           (string-prefix-p "Error executing tool " result)
           (string-prefix-p "Approval denied for tool " result))))

(defun chat-work--workflow-finish-step (id index status result error)
  "Finish workflow ID step INDEX and continue when successful."
  (when-let ((workflow (chat-work--workflow-find id)))
    (when (and (equal (chat-work--json-get workflow 'status) "running")
               (= (or (chat-work--json-get workflow 'stepIndex) -1)
                  index))
      (setq workflow
            (chat-work--workflow-record-result workflow index status
                                               result error))
      (if error
          (setq workflow
                (chat-work--alist-set
                 (chat-work--alist-set workflow 'status "paused")
                 'error error))
        (setq workflow
              (chat-work--alist-set
               (chat-work--alist-set workflow 'stepIndex (1+ index))
               'error nil)))
      (chat-work--workflow-store workflow)
      (unless error
        (chat-work--workflow-drive id)))))

(defun chat-work--workflow-drive (id)
  "Run workflow ID from its persisted step index."
  (let ((workflow (chat-work--workflow-find id)))
    (unless workflow
      (error "Workflow not found: %s" id))
    (when (equal (chat-work--json-get workflow 'status) "running")
      (let* ((index (or (chat-work--json-get workflow 'stepIndex) 0))
             (steps (chat-work--json-get workflow 'steps))
             (step (nth index steps)))
        (if (null step)
            (progn
              (setq workflow
                    (chat-work--alist-set
                     (chat-work--alist-set workflow 'status "completed")
                     'completedAt (chat-work--timestamp)))
              (chat-work--workflow-store workflow))
          (let ((condition (chat-work--json-get step 'when))
                (kind (chat-work--json-get step 'kind)))
            (cond
             ((not (chat-work--workflow-condition-p workflow condition))
              (setq workflow
                    (chat-work--workflow-record-result
                     workflow index "skipped" nil nil))
              (setq workflow
                    (chat-work--alist-set workflow 'stepIndex (1+ index)))
              (chat-work--workflow-store workflow)
              (chat-work--workflow-drive id))
             ((equal kind "approval")
              (setq workflow
                    (chat-work--alist-set workflow 'status
                                         "awaiting-approval"))
              (chat-work--workflow-store workflow))
             (t
              (let* ((session (chat-work--current-session))
                     (name (chat-work--json-get step 'name))
                     (arguments
                      (chat-work--workflow-string-arguments
                       (or (chat-work--json-get step 'arguments) nil)))
                     (call (list :id (format "%s:%d" id index)
                                 :name name
                                 :arguments arguments)))
                (chat-tool-caller-execute-async
                 call session nil
                 (lambda (result)
                   (let ((chat-tool-caller-current-session session))
                     (if (chat-work--workflow-tool-error-result-p result)
                         (chat-work--workflow-finish-step
                          id index "failed" nil result)
                       (chat-work--workflow-finish-step
                        id index "succeeded" result nil))))
                 (lambda (message)
                   (let ((chat-tool-caller-current-session session))
                     (chat-work--workflow-finish-step
                      id index "failed" nil message)))))))))))
    (chat-work--workflow-find id)))

(defun chat-work-workflow-start (name steps-json)
  "Create and start resumable declarative workflow NAME from STEPS-JSON."
  (let* ((json-array-type 'list)
         (json-object-type 'alist)
         (json-key-type 'symbol)
         (steps (chat-work--workflow-validate-steps
                 (json-read-from-string steps-json)))
         (workflow `((id . ,(chat-session-new-message-id "workflow"))
                     (name . ,name)
                     (status . "running")
                     (stepIndex . 0)
                     (steps . ,steps)
                     (results . nil)
                     (createdAt . ,(chat-work--timestamp))
                     (updatedAt . ,(chat-work--timestamp)))))
    (chat-work--workflow-store workflow)
    (chat-work--workflow-drive (chat-work--json-get workflow 'id))))

(defun chat-work-workflow-resume (id &optional decision)
  "Resume workflow ID, optionally applying checkpoint DECISION.
DECISION is `approve' or `reject' when the workflow awaits approval."
  (let ((workflow (chat-work--workflow-find id)))
    (unless workflow
      (error "Workflow not found: %s" id))
    (let ((status (chat-work--json-get workflow 'status))
          (index (or (chat-work--json-get workflow 'stepIndex) 0)))
      (cond
       ((member status '("completed" "cancelled"))
        (error "Workflow is already %s" status))
       ((equal status "awaiting-approval")
        (unless (member decision '("approve" "reject"))
          (error "Workflow requires an approve or reject decision"))
        (if (equal decision "reject")
            (progn
              (setq workflow
                    (chat-work--workflow-record-result
                     workflow index "rejected" nil "Checkpoint rejected"))
              (setq workflow
                    (chat-work--alist-set workflow 'status "cancelled"))
              (chat-work--workflow-store workflow))
          (setq workflow
                (chat-work--workflow-record-result
                 workflow index "approved" "approved" nil))
          (setq workflow
                (chat-work--alist-set
                 (chat-work--alist-set workflow 'stepIndex (1+ index))
                 'status "running"))
          (chat-work--workflow-store workflow)
          (chat-work--workflow-drive id)))
       (t
        (setq workflow
              (chat-work--alist-set
               (chat-work--alist-set workflow 'status "running")
               'error nil))
        (chat-work--workflow-store workflow)
        (chat-work--workflow-drive id))))))

(defun chat-work-workflow-cancel (id)
  "Cancel workflow ID."
  (let* ((state (chat-work--state))
         (workflows (chat-work--state-get state 'workflows))
         found)
    (setq workflows
          (mapcar (lambda (workflow)
                    (if (equal (chat-work--json-get workflow 'id) id)
                        (progn
                          (setq found t)
                          (if (equal (chat-work--json-get workflow 'status)
                                     "completed")
                              (error "Completed workflow cannot be cancelled")
                            (chat-work--alist-set workflow 'status
                                                  "cancelled")))
                      workflow))
                  workflows))
    (unless found
      (error "Workflow not found: %s" id))
    (let ((workflow
           (cl-find id workflows
                    :key (lambda (entry)
                           (chat-work--json-get entry 'id))
                    :test #'equal)))
      (chat-work--set-state
       (chat-work--state-put state 'workflows workflows))
      (chat-work--sync-workflow-task workflow)
      workflow)))

(defun chat-work-workflow-list ()
  "List session-local workflow records."
  (let ((workflows (chat-work--state-get (chat-work--state) 'workflows)))
    (mapc #'chat-work--sync-workflow-task workflows)
    workflows))

(defun chat-work--register-tool (id name description parameters fn effects)
  "Register a work orchestration tool."
  (chat-tool-forge-register
   (make-chat-forged-tool
    :id id
    :name name
    :description description
    :language 'elisp
    :parameters parameters
    :owner 'work
    :sensitivity 'project
    :effects effects
    :compiled-function fn
    :is-active t
    :usage-count 0)))

(defun chat-work-register-tools ()
  "Register work orchestration tools."
  (chat-work--register-tool
   'work_task_start "Work Task Start"
   ;; Generated, so that adding a program to the variable changes what the
   ;; model is told.  Written out, the two drift and the description wins,
   ;; because the description is the only one the model reads.
   (concat "Start a cancellable background shell task. "
           "Chaining with && || ; and | is accepted and every command in "
           "the chain is checked. Redirection, background jobs and command "
           "substitution are not accepted. "
           (chat-command-gate-describe chat-work-task-allowed-commands))
   '((:name "command" :type "string" :required t)
     (:name "directory" :type "string" :required nil))
   #'chat-work-task-start
   '(write outbound))
  (chat-work--register-tool
   'work_task_list "Work Task List"
   "List known background tasks."
   nil #'chat-work-task-list '(read))
  (chat-work--register-tool
   'work_task_output "Work Task Output"
   "Read bounded output from a background task."
   '((:name "id" :type "string" :required t))
   #'chat-work-task-output '(read))
  (chat-work--register-tool
   'work_task_stop "Work Task Stop"
   "Stop a running background task."
   '((:name "id" :type "string" :required t))
   #'chat-work-task-stop '(write))
  (chat-work--register-tool
   'work_plan_enter "Work Plan Enter"
   "Enter session-local planning state."
   '((:name "title" :type "string" :required t))
   #'chat-work-plan-enter '(write))
  (chat-work--register-tool
   'work_plan_exit "Work Plan Exit"
   "Exit session-local planning state."
   nil #'chat-work-plan-exit '(write))
  (chat-work--register-tool
   'work_todo_add "Work Todo Add"
   "Add a session-local TODO record."
   '((:name "title" :type "string" :required t))
   #'chat-work-todo-add '(write))
  (chat-work--register-tool
   'work_todo_update "Work Todo Update"
   "Update a session-local TODO status."
   '((:name "id" :type "string" :required t)
     (:name "status" :type "string" :required t))
   #'chat-work-todo-update '(write))
  (chat-work--register-tool
   'work_todo_list "Work Todo List"
   "List session-local TODO records."
   nil #'chat-work-todo-list '(read))
  (chat-work--register-tool
   'work_goal_add "Work Goal Add"
   "Retired compatibility entry; use programming_goal_create."
   '((:name "title" :type "string" :required t))
   #'chat-work-goal-add '(write))
  (chat-work--register-tool
   'work_goal_update "Work Goal Update"
   "Retired compatibility entry; use revision-checked Goal lifecycle tools."
   '((:name "id" :type "string" :required t)
     (:name "status" :type "string" :required t))
   #'chat-work-goal-update '(write))
  (chat-work--register-tool
   'work_goal_list "Work Goal List"
   "List session-local goal records."
   nil #'chat-work-goal-list '(read))
  (chat-work--register-tool
   'work_workflow_start "Work Workflow Start"
   "Start an ordered declarative workflow of tool and approval steps."
   '((:name "name" :type "string" :required t)
     (:name "steps_json" :type "string" :required t))
   #'chat-work-workflow-start '(write))
  (chat-work--register-tool
   'work_workflow_resume "Work Workflow Resume"
   "Resume a paused workflow or decide its approval checkpoint."
   '((:name "id" :type "string" :required t)
     (:name "decision" :type "string" :required nil
      :enum ("approve" "reject")))
   #'chat-work-workflow-resume '(write))
  (chat-work--register-tool
   'work_workflow_cancel "Work Workflow Cancel"
   "Cancel a declarative workflow record."
   '((:name "id" :type "string" :required t))
   #'chat-work-workflow-cancel '(write))
  (chat-work--register-tool
   'work_workflow_list "Work Workflow List"
   "List session-local workflow records."
   nil #'chat-work-workflow-list '(read)))

(provide 'chat-work)
;;; chat-work.el ends here
