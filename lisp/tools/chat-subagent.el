;;; chat-subagent.el --- Sub-agent backends for chat.el -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: chat, agents

;; This file is not part of GNU Emacs.

;;; Commentary:

;; In-process and external subprocess-agent backends.  Parent sessions
;; receive summarized records rather than child transcripts.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'chat-event)
(require 'chat-execution)
(require 'chat-session)
(require 'chat-task)
(require 'chat-agent)
(require 'chat-tool-forge)

(defgroup chat-subagent nil
  "Sub-agent execution for chat.el."
  :group 'chat)

(defcustom chat-subagent-max-depth 2
  "Maximum nested sub-agent depth."
  :type 'integer
  :group 'chat)

(defcustom chat-subagent-default-budget 10
  "Default step budget for sub-agent records."
  :type 'integer
  :group 'chat)

(defcustom chat-subagent-directory
  (expand-file-name "~/.chat/subagents/")
  "Directory for external sub-agent protocol logs."
  :type 'directory
  :group 'chat-subagent)

(cl-defstruct chat-subagent
  id
  kind
  name
  status
  depth
  budget
  parent-session
  child-session
  summary
  log-file
  process
  run
  events
  started-at
  ended-at)

(defvar chat-subagent--registry (make-hash-table :test 'equal)
  "Known sub-agents keyed by id.")

(defvar chat-tool-caller-current-session)

(defun chat-subagent--id ()
  "Return a fresh sub-agent id."
  (chat-session-new-message-id "subagent"))

(defun chat-subagent--max-depth (&optional session)
  "Return the effective nested-agent depth limit for SESSION."
  (let ((profile-limit
         (and session
              (plist-get (chat-session-tool-config session)
                         :subagent-max-depth))))
    (if (and (integerp profile-limit) (> profile-limit 0))
        (min chat-subagent-max-depth profile-limit)
      chat-subagent-max-depth)))

(defun chat-subagent--ensure-depth (depth &optional session)
  "Signal when DEPTH exceeds the effective limit for SESSION."
  (let ((limit (chat-subagent--max-depth session)))
    (when (> depth limit)
      (error "Sub-agent depth limit exceeded: %s > %s" depth limit))))

(defun chat-subagent--timestamp ()
  "Return a stable timestamp string."
  (format-time-string "%Y-%m-%dT%H:%M:%S" (current-time)))

(defun chat-subagent--event-payload (subagent)
  "Return bounded lifecycle facts for SUBAGENT."
  (delq nil
        (list
         (cons 'name (chat-subagent-name subagent))
         (cons 'kind (format "%s" (chat-subagent-kind subagent)))
         (cons 'status (format "%s" (chat-subagent-status subagent)))
         (cons 'depth (chat-subagent-depth subagent))
         (cons 'budget (chat-subagent-budget subagent))
         (when-let* ((child (chat-subagent-child-session subagent)))
           (cons 'child_session_id (chat-session-id child)))
         (when (stringp (chat-subagent-summary subagent))
           (cons 'summary_chars
                 (length (chat-subagent-summary subagent)))))))

(defun chat-subagent--emit-event (type subagent)
  "Publish lifecycle TYPE for SUBAGENT."
  (let ((parent (chat-subagent-parent-session subagent)))
    (chat-event-emit
     type
     :session-id (and parent (chat-session-id parent))
     :task-id (chat-subagent-id subagent)
     :source 'subagent
     :subject subagent
     :payload (chat-subagent--event-payload subagent))))

(defun chat-subagent--parent-task-id (session)
  "Return the live task that owns SESSION, when known."
  (when session
    (let* ((metadata (chat-session-metadata session))
           (id (or (cdr (assoc 'activeTaskId metadata))
                   (cdr (assoc 'parentTaskId metadata)))))
      (when-let* ((task (and id (chat-task-get id))))
        (and (eq (chat-task-status task) 'running) id)))))

(defun chat-subagent--task-status (status)
  "Return canonical task status for sub-agent STATUS."
  (pcase status
    ((or 'completed 'stopped) 'completed)
    ((or 'failed 'error) 'failed)
    ('cancelled 'canceled)
    ('interrupted 'interrupted)
    (_ 'running)))

(defun chat-subagent--register-runtime-task (subagent)
  "Register SUBAGENT as a running durable runtime task."
  (let* ((parent (chat-subagent-parent-session subagent))
         (child (chat-subagent-child-session subagent))
         (task
          (chat-task-adopt
           :id (chat-subagent-id subagent)
           :parent-id (chat-subagent--parent-task-id parent)
           :kind 'subagent
           :title (chat-subagent-name subagent)
           :status 'queued
           :session-id (and parent (chat-session-id parent))
           :source 'subagent
           :payload
           `((kind . ,(symbol-name (chat-subagent-kind subagent)))
             (depth . ,(chat-subagent-depth subagent))
             (budget . ,(chat-subagent-budget subagent))
             (childSessionId . ,(and child (chat-session-id child))))
           :metadata '((adapter . "subagent"))
           :child-policy 'cancel
           :cancel-function
           (lambda (_task reason)
             (chat-subagent--cancel-live subagent reason)))))
    (chat-task-transition task 'running)
    task))

(defun chat-subagent--sync-runtime-task (subagent)
  "Synchronize SUBAGENT's terminal outcome to its runtime task."
  (when-let* ((task (chat-task-get (chat-subagent-id subagent))))
    (let ((status (chat-subagent--task-status
                   (chat-subagent-status subagent))))
      (chat-task-transition
       task status
       :result (and (eq status 'completed)
                    (chat-subagent-summary subagent))
       :error (and (eq status 'failed)
                   (chat-subagent-summary subagent))))))

(defun chat-subagent--terminal-p (subagent)
  "Return non-nil when SUBAGENT already finished."
  (memq (chat-subagent-status subagent)
        '(completed stopped failed error cancelled interrupted)))

(defun chat-subagent--finish (subagent status &optional summary)
  "Finish SUBAGENT once with STATUS and optional SUMMARY."
  (unless (chat-subagent--terminal-p subagent)
    (setf (chat-subagent-status subagent) status
          (chat-subagent-summary subagent) summary
          (chat-subagent-ended-at subagent) (chat-subagent--timestamp))
    (chat-subagent--sync-runtime-task subagent)
    (chat-subagent--emit-event 'subagent-ended subagent))
  subagent)

(defun chat-subagent--cancel-live (subagent reason)
  "Cancel SUBAGENT's live adapter with REASON."
  (unless (chat-subagent--terminal-p subagent)
    (cond
     ((and (chat-subagent-run subagent)
           (chat-agent-active-p (chat-subagent-run subagent)))
      (chat-agent-cancel (chat-subagent-run subagent)))
     ((and (chat-subagent-process subagent)
           (process-live-p (chat-subagent-process subagent)))
      (let ((process (chat-subagent-process subagent)))
        (if-let* ((record (chat-execution-record-for-native process)))
            (chat-execution-cancel record reason)
          (delete-process process)))
      (chat-subagent--finish subagent 'cancelled reason))
     (t
      (chat-subagent--finish subagent 'cancelled reason))))
  subagent)

(defun chat-subagent--session-depth (session)
  "Return nesting depth recorded on SESSION."
  (or (and session
           (cdr (assoc 'subagentDepth
                       (chat-session-metadata session))))
      0))

(defun chat-subagent--child-session
    (name messages parent depth &optional parent-task-id)
  "Create isolated child session NAME with MESSAGES.

The child inherits the parent's approval mode and nothing else about
permission.  Session-scoped grants stay behind: those are one person's
decisions about the commands they were shown, not a licence handed to a
sub-agent that will run commands nobody sees."
  (make-chat-session
   :id (chat-session-new-message-id "child-session")
   :name name
   :created-at (current-time)
   :updated-at (current-time)
   :model-id (or (and parent (chat-session-model-id parent)) 'kimi)
   :model-name (and parent (chat-session-model-name parent))
   :messages messages
   :tool-config (copy-tree (and parent
                                (chat-session-tool-config parent)))
   :approval-mode (or (and parent (chat-session-approval-mode parent))
                      'inherit)
   :metadata (delq nil
                   `((subagentDepth . ,depth)
                     ,(when parent-task-id
                        (cons 'parentTaskId parent-task-id))))
   :parent-session-id (and parent (chat-session-id parent))))

(defun chat-subagent-start-in-process (name messages runner
                                            &optional parent-session depth budget)
  "Start an in-process sub-agent NAME with MESSAGES and RUNNER.
RUNNER is a function called with the child session and must return a
summary string or alist.  This helper provides isolated child-session
  state without dumping child transcripts into the parent."
  (let ((depth (or depth 0)))
    (chat-subagent--ensure-depth depth parent-session)
    (let* ((id (chat-subagent--id))
           (child-session
            (chat-subagent--child-session
             name messages parent-session depth id))
           (subagent (make-chat-subagent
                      :id id
                      :kind 'in-process
                      :name name
                      :status 'running
                      :depth depth
                      :budget (or budget chat-subagent-default-budget)
                      :parent-session parent-session
                      :child-session child-session
                      :started-at (chat-subagent--timestamp))))
      (puthash (chat-subagent-id subagent) subagent chat-subagent--registry)
      (chat-subagent--register-runtime-task subagent)
      (chat-subagent--emit-event 'subagent-started subagent)
      (condition-case err
          (let ((summary (funcall runner child-session)))
            (chat-subagent--finish subagent 'completed summary)
            subagent)
        (error
         (chat-subagent--finish
          subagent 'failed (error-message-string err))
         subagent)))))

(defun chat-subagent-start-agent
    (name prompt parent-session success error-callback &optional budget options)
  "Start nested agent NAME for PROMPT and report through callbacks.

OPTIONS may declare `:profile', `:provider', `:model', `:project-root' and
`:base-revision'.  PROVIDER names the adapter and MODEL is its concrete remote
model id.  A project root creates a session-owned worktree before the agent
starts."
  (let* ((depth (1+ (chat-subagent--session-depth parent-session)))
         (_ (chat-subagent--ensure-depth depth parent-session))
         (id (chat-subagent--id))
         (profile (plist-get options :profile))
         (parent-provider (and parent-session
                               (chat-session-model-id parent-session)))
         (provider (or (plist-get options :provider)
                       parent-provider
                       'kimi))
         (model (or (plist-get options :model)
                    (and (eq provider parent-provider)
                         parent-session
                         (chat-session-model-name parent-session))
                    (plist-get (chat-llm-get-provider-config provider)
                               :model)))
         (message
          (make-chat-message
           :id (chat-session-new-message-id "subagent-user")
           :role :user
           :content prompt
           :timestamp (current-time)))
         (child-session
          (chat-subagent--child-session
           name (list message) parent-session depth id))
         (_identity
          (setf (chat-session-model-id child-session) provider
                (chat-session-model-name child-session) model))
         (_profile
          (when profile
            (chat-session-set-tool-config child-session
                                          (list :profile profile))))
         (workspace
          (when-let* ((root (plist-get options :project-root)))
            (require 'chat-workspace)
            (chat-workspace-enable-worktree
             child-session root
             :revision (plist-get options :base-revision))))
         (subagent
          (make-chat-subagent
           :id id
           :kind 'in-process
           :name name
           :status 'running
           :depth depth
           :budget (or budget chat-subagent-default-budget)
           :parent-session parent-session
           :child-session child-session
           :started-at (chat-subagent--timestamp)))
         run)
    (puthash (chat-subagent-id subagent) subagent chat-subagent--registry)
    (chat-subagent--register-runtime-task subagent)
    (chat-subagent--emit-event 'subagent-started subagent)
    (chat-session-save child-session)
    (condition-case err
        (setq
         run
         (chat-agent-start
          (list
           :provider provider
           :model model
           :messages (list message)
           :session child-session
           :profile profile
       :project-root (chat-session-working-directory child-session)
       :transport 'stream
       :max-steps (chat-subagent-budget subagent)
       :on-event
       (lambda (event)
         (push (list :type (plist-get event :type)
                     :step (plist-get event :step))
               (chat-subagent-events subagent))
         (when (eq (plist-get event :type) 'message-appended)
           (chat-session-add-message child-session
                                     (plist-get event :message)))
         (when (eq (plist-get event :type) 'agent-end)
           (let ((status (plist-get event :status))
                 (content (or (plist-get event :content) "")))
             (chat-subagent--finish subagent status content)
             (if (memq status '(completed stopped))
                 (funcall success
                          `((id . ,(chat-subagent-id subagent))
                            (status . ,(symbol-name status))
                            (summary . ,content)))
               (funcall error-callback
                        (if (string-empty-p content)
                            (format "Sub-agent %s" status)
                          content)))))))))
      (error
       (let ((message (error-message-string err)))
         (chat-subagent--finish subagent 'failed message)
         (funcall error-callback message))))
    (setf (chat-subagent-run subagent) run)
    (list :subagent subagent
          :child-session child-session
          :workspace workspace
          :cancel
          (lambda ()
            (when (and run (chat-agent-active-p run))
              (chat-agent-cancel run))))))

(defun chat-subagent-start-external (name command input-jsonl log-file
                                          &optional depth budget parent-session id)
  "Start external subprocess-agent NAME using COMMAND.
INPUT-JSONL is written to the subprocess stdin when non-nil.  Output is
captured in LOG-FILE."
  (let ((depth (or depth 0)))
    (chat-subagent--ensure-depth depth parent-session)
    (make-directory (file-name-directory log-file) t)
    (let* ((subagent (make-chat-subagent
                      :id (or id (chat-subagent--id))
                      :kind 'external
                      :name name
                      :status 'running
                      :depth depth
                      :budget (or budget chat-subagent-default-budget)
                      :parent-session parent-session
                      :log-file log-file
                      :started-at (chat-subagent--timestamp)))
           proc)
      (puthash (chat-subagent-id subagent) subagent chat-subagent--registry)
      (chat-subagent--register-runtime-task subagent)
      (chat-subagent--emit-event 'subagent-started subagent)
      (with-temp-file log-file)
      (condition-case err
          (progn
            (let ((record
                   (chat-execution-start
                    (chat-execution-request-from-context
                     command
                     :session-id (and parent-session
                                      (chat-session-id parent-session))
                     :task-id (chat-subagent-id subagent)
                     :parent-id (chat-subagent--parent-task-id parent-session)
                     :idempotency 'non-idempotent
                     :metadata '((kind . "external-subagent")))
                    :name (concat "chat-subagent-"
                                  (chat-subagent-id subagent))
                    :buffer nil
                    :connection-type 'pipe
                    :noquery t
                    :filter (lambda (_proc chunk)
                              (write-region chunk nil log-file 'append 'silent))
                    :sentinel (lambda (process _event)
                                (unless (process-live-p process)
                                  (chat-subagent--finish
                                   subagent
                                   (if (zerop (process-exit-status process))
                                       'completed
                                     'failed)
                                   (chat-subagent--external-summary
                                    log-file)))))))
              (setq proc (chat-execution-native-handle record)))
            (setf (chat-subagent-process subagent) proc)
            (when input-jsonl
              (process-send-string proc input-jsonl))
            (process-send-eof proc)
            subagent)
        (error
         (chat-subagent--finish
          subagent 'failed (error-message-string err))
         (signal (car err) (cdr err)))))))

(defun chat-subagent--external-summary (log-file)
  "Return summary from the last valid JSONL record in LOG-FILE."
  (when (file-exists-p log-file)
    (with-temp-buffer
      (insert-file-contents log-file)
      (let ((lines (reverse
                    (split-string (buffer-string) "\n" t)))
            summary)
        (while (and lines (null summary))
          (let ((line (pop lines)))
            (condition-case nil
                (let* ((json-object-type 'alist)
                       (record (json-read-from-string line)))
                (setq summary
                      (or (cdr (assoc 'summary record))
                          (cdr (assoc 'content record)))))
              (error nil))))
        (or summary (string-trim (buffer-string)))))))

(defun chat-subagent-start-external-tool
    (name command-json prompt &optional budget)
  "Start external NAME from COMMAND-JSON with JSONL PROMPT."
  (let* ((json-array-type 'list)
         (command (json-read-from-string command-json)))
    (unless (and (listp command)
                 command
                 (cl-every #'stringp command))
      (error "External sub-agent command must be a JSON string array"))
    (make-directory chat-subagent-directory t)
    (let* ((id (chat-subagent--id))
           (log-file (expand-file-name (concat id ".jsonl")
                                       chat-subagent-directory))
           (input (concat
                   (json-encode
                    `((type . "request")
                      (prompt . ,prompt)
                      (budget . ,(or budget
                                     chat-subagent-default-budget))))
                   "\n")))
      (chat-subagent-start-external
       name command input log-file 0 budget
       chat-tool-caller-current-session id)
      (chat-subagent-describe id))))

(defun chat-subagent-cancel (id)
  "Cancel sub-agent ID."
  (let ((subagent (gethash id chat-subagent--registry)))
    (unless subagent
      (error "Sub-agent not found: %s" id))
    (if (chat-task-get id)
        (chat-task-cancel id "cancelled by user")
      (chat-subagent--cancel-live subagent "cancelled by user"))
    subagent))

(defun chat-subagent-describe (id)
  "Return a parent-safe summary for sub-agent ID."
  (let ((subagent (gethash id chat-subagent--registry)))
    (unless subagent
      (error "Sub-agent not found: %s" id))
    `((id . ,(chat-subagent-id subagent))
      (name . ,(chat-subagent-name subagent))
      (kind . ,(symbol-name (chat-subagent-kind subagent)))
      (status . ,(symbol-name (chat-subagent-status subagent)))
      (summary . ,(chat-subagent-summary subagent))
      (logFile . ,(chat-subagent-log-file subagent))
      (depth . ,(chat-subagent-depth subagent))
      (budget . ,(chat-subagent-budget subagent))
      (startedAt . ,(chat-subagent-started-at subagent))
      (endedAt . ,(chat-subagent-ended-at subagent)))))

(defun chat-subagent-external-output (id)
  "Return captured external sub-agent output for ID."
  (let ((subagent (gethash id chat-subagent--registry)))
    (unless subagent
      (error "Sub-agent not found: %s" id))
    (if (and (chat-subagent-log-file subagent)
             (file-exists-p (chat-subagent-log-file subagent)))
        (with-temp-buffer
          (insert-file-contents (chat-subagent-log-file subagent))
          (buffer-string))
      "")))

(defun chat-subagent-list ()
  "Return parent-safe summaries for all known sub-agents."
  (let (items)
    (maphash (lambda (id _subagent)
               (push (chat-subagent-describe id) items))
             chat-subagent--registry)
    (nreverse items)))

(defun chat-subagent-run-tool-async (argv success error-callback)
  "Run nested agent from tool ARGV."
  (pcase-let ((`(,name ,prompt ,budget) argv))
    (condition-case err
        (chat-subagent-start-agent
         name prompt chat-tool-caller-current-session
         success error-callback budget)
      (error
       (funcall error-callback (error-message-string err))))))

(defun chat-subagent--async-only (&rest _args)
  "Signal when an asynchronous-only sub-agent tool is called directly."
  (error "Sub-agent run requires asynchronous tool execution"))

(defun chat-subagent--register-tool
    (id name description parameters fn effects &optional async-fn sensitivity)
  "Register one sub-agent integration tool."
  (chat-tool-forge-register
   (make-chat-forged-tool
    :id id :name name :description description :language 'elisp
    :parameters parameters :owner 'subagent
    :sensitivity (or sensitivity 'project)
    :effects effects :compiled-function fn :async-function async-fn
    :is-active t :usage-count 0)))

(defun chat-subagent-register-tools ()
  "Register in-process and external sub-agent tools."
  (chat-subagent--register-tool
   'subagent_run "Sub-agent Run"
   "Run an isolated nested agent and return only its final summary."
   '((:name "name" :type "string" :required t)
     (:name "prompt" :type "string" :required t)
     (:name "budget" :type "integer" :required nil))
   #'chat-subagent--async-only '(read outbound)
   #'chat-subagent-run-tool-async)
  (chat-subagent--register-tool
   'subagent_list "Sub-agent List"
   "List parent-safe status summaries for known sub-agents."
   nil #'chat-subagent-list '(read))
  (chat-subagent--register-tool
   'subagent_status "Sub-agent Status"
   "Read one sub-agent status without exposing its child transcript."
   '((:name "id" :type "string" :required t))
   #'chat-subagent-describe '(read))
  (chat-subagent--register-tool
   'subagent_cancel "Sub-agent Cancel"
   "Cancel a running nested or external sub-agent."
   '((:name "id" :type "string" :required t))
   #'chat-subagent-cancel '(write))
  (chat-subagent--register-tool
   'subagent_external_start "Sub-agent External Start"
   "Start a configured command-array subprocess using a JSONL request."
   '((:name "name" :type "string" :required t)
     (:name "command_json" :type "string" :required t)
     (:name "prompt" :type "string" :required t)
     (:name "budget" :type "integer" :required nil))
   #'chat-subagent-start-external-tool '(execute outbound)
   nil 'restricted)
  (chat-subagent--register-tool
   'subagent_external_output "Sub-agent External Output"
   "Read captured JSONL output from an external sub-agent."
   '((:name "id" :type "string" :required t))
   #'chat-subagent-external-output '(read)))

(provide 'chat-subagent)
;;; chat-subagent.el ends here
