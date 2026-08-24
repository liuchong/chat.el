;;; chat-work.el --- Work orchestration services for chat.el -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: chat, tasks, workflows

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Background tasks, session-local work records, and declarative
;; workflow state.  Workflow records are data only; they do not evaluate
;; arbitrary Lisp.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'chat-session)
(require 'chat-tool-forge)

(defgroup chat-work nil
  "Work orchestration for chat.el."
  :group 'chat)

(defcustom chat-work-directory
  (expand-file-name "~/.chat/work/")
  "Directory where background task state and logs are stored."
  :type 'directory
  :group 'chat-work)

(defcustom chat-work-task-output-max-chars 20000
  "Maximum background task output returned from one tool call."
  :type 'integer
  :group 'chat-work)

(cl-defstruct chat-work-task
  id
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

(defun chat-work--task-to-json (task)
  "Convert TASK to JSON-friendly data."
  `((id . ,(chat-work-task-id task))
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
      (insert (json-encode `((tasks . ,(vconcat (nreverse tasks)))))))))

(defun chat-work-load-tasks ()
  "Load background task state and mark stale running tasks interrupted."
  (chat-work--ensure-directory)
  (clrhash chat-work--tasks)
  (let ((file (chat-work--state-file)))
    (when (file-exists-p file)
      (let* ((json-array-type 'list)
             (data (condition-case nil
                       (with-temp-buffer
                         (insert-file-contents file)
                         (json-read-from-string (buffer-string)))
                     (error nil)))
             (tasks (cdr (assoc 'tasks data))))
        (dolist (entry tasks)
          (let ((task (chat-work--task-from-json entry)))
            (when (eq (chat-work-task-status task) 'running)
              (setf (chat-work-task-status task) 'interrupted
                    (chat-work-task-ended-at task) (chat-work--timestamp)))
            (puthash (chat-work-task-id task) task chat-work--tasks))))))
  (hash-table-count chat-work--tasks))

(defun chat-work-task-start (command &optional directory)
  "Start COMMAND as a cancellable background task in DIRECTORY."
  (chat-work--ensure-directory)
  (let* ((id (chat-work--task-id))
         (default-directory (file-name-as-directory
                             (or directory default-directory)))
         (log-file (expand-file-name (concat id ".log") chat-work-directory))
         (task (make-chat-work-task
                :id id
                :command command
                :directory default-directory
                :status 'running
                :started-at (chat-work--timestamp)
                :log-file log-file))
         process)
    (with-temp-file log-file)
    (setq process
          (make-process
           :name (concat "chat-work-" id)
           :buffer nil
           :command (list shell-file-name shell-command-switch command)
           :noquery t
           :filter (lambda (_proc chunk)
                     (write-region chunk nil log-file 'append 'silent))
           :sentinel (lambda (proc _event)
                       (unless (process-live-p proc)
                         (unless (eq (chat-work-task-status task)
                                     'cancelled)
                           (setf (chat-work-task-status task)
                                 (if (zerop (process-exit-status proc))
                                     'succeeded
                                   'failed)
                                 (chat-work-task-exit-code task)
                                 (process-exit-status proc)
                                 (chat-work-task-ended-at task)
                                 (chat-work--timestamp)))
                         (chat-work-save-tasks)))))
    (setf (chat-work-task-process task) process)
    (puthash id task chat-work--tasks)
    (chat-work-save-tasks)
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
    (when-let ((proc (chat-work-task-process task)))
      (when (process-live-p proc)
        (delete-process proc)))
    (setf (chat-work-task-status task) 'cancelled
          (chat-work-task-ended-at task) (chat-work--timestamp))
    (chat-work-save-tasks)
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
  "Add a session-local goal with TITLE."
  (chat-work--record-add 'goals title))

(defun chat-work-goal-update (id status)
  "Update goal ID to STATUS."
  (chat-work--record-update 'goals id status))

(defun chat-work-goal-list ()
  "List session-local goal records."
  (chat-work--state-get (chat-work--state) 'goals))

(defun chat-work-workflow-start (name steps-json)
  "Start a declarative workflow NAME from STEPS-JSON."
  (let* ((json-array-type 'list)
         (steps (json-read-from-string steps-json))
         (state (chat-work--state))
         (workflows (chat-work--state-get state 'workflows))
         (workflow `((id . ,(chat-session-new-message-id "workflow"))
                     (name . ,name)
                     (status . "running")
                     (stepIndex . 0)
                     (steps . ,steps)
                     (createdAt . ,(chat-work--timestamp)))))
    (unless (listp steps)
      (error "Workflow steps must be a JSON array"))
    (chat-work--set-state
     (chat-work--state-put state 'workflows
                           (append workflows (list workflow))))
    workflow))

(defun chat-work-workflow-cancel (id)
  "Cancel workflow ID."
  (let* ((state (chat-work--state))
         (workflows (chat-work--state-get state 'workflows))
         found)
    (setq workflows
          (mapcar (lambda (workflow)
                    (if (equal (cdr (assoc 'id workflow)) id)
                        (progn
                          (setq found t)
                          (cons '(status . "cancelled")
                                (assq-delete-all 'status
                                                 (copy-tree workflow))))
                      workflow))
                  workflows))
    (unless found
      (error "Workflow not found: %s" id))
    (chat-work--set-state (chat-work--state-put state 'workflows workflows))
    (cl-find id workflows :key (lambda (workflow) (cdr (assoc 'id workflow)))
             :test #'equal)))

(defun chat-work-workflow-list ()
  "List session-local workflow records."
  (chat-work--state-get (chat-work--state) 'workflows))

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
   "Start a cancellable background shell task."
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
   "Add a session-local goal record."
   '((:name "title" :type "string" :required t))
   #'chat-work-goal-add '(write))
  (chat-work--register-tool
   'work_goal_update "Work Goal Update"
   "Update a session-local goal status."
   '((:name "id" :type "string" :required t)
     (:name "status" :type "string" :required t))
   #'chat-work-goal-update '(write))
  (chat-work--register-tool
   'work_goal_list "Work Goal List"
   "List session-local goal records."
   nil #'chat-work-goal-list '(read))
  (chat-work--register-tool
   'work_workflow_start "Work Workflow Start"
   "Create a declarative workflow record from JSON steps."
   '((:name "name" :type "string" :required t)
     (:name "steps_json" :type "string" :required t))
   #'chat-work-workflow-start '(write))
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
