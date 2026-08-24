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
(require 'chat-session)
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

(defun chat-subagent--ensure-depth (depth)
  "Signal when DEPTH exceeds `chat-subagent-max-depth'."
  (when (> depth chat-subagent-max-depth)
    (error "Sub-agent depth limit exceeded: %s" depth)))

(defun chat-subagent--timestamp ()
  "Return a stable timestamp string."
  (format-time-string "%Y-%m-%dT%H:%M:%S" (current-time)))

(defun chat-subagent--session-depth (session)
  "Return nesting depth recorded on SESSION."
  (or (and session
           (cdr (assoc 'subagentDepth
                       (chat-session-metadata session))))
      0))

(defun chat-subagent--child-session (name messages parent depth)
  "Create isolated child session NAME with MESSAGES."
  (make-chat-session
   :id (chat-session-new-message-id "child-session")
   :name name
   :created-at (current-time)
   :updated-at (current-time)
   :model-id (or (and parent (chat-session-model-id parent)) 'kimi)
   :messages messages
   :tool-config (copy-tree (and parent
                                (chat-session-tool-config parent)))
   :metadata `((subagentDepth . ,depth))
   :parent-session-id (and parent (chat-session-id parent))))

(defun chat-subagent-start-in-process (name messages runner
                                            &optional parent-session depth budget)
  "Start an in-process sub-agent NAME with MESSAGES and RUNNER.
RUNNER is a function called with the child session and must return a
summary string or alist.  This helper provides isolated child-session
state without dumping child transcripts into the parent."
  (let ((depth (or depth 0)))
    (chat-subagent--ensure-depth depth)
    (let* ((child-session
            (chat-subagent--child-session
             name messages parent-session depth))
           (subagent (make-chat-subagent
                      :id (chat-subagent--id)
                      :kind 'in-process
                      :name name
                      :status 'running
                      :depth depth
                      :budget (or budget chat-subagent-default-budget)
                      :parent-session parent-session
                      :child-session child-session
                      :started-at (chat-subagent--timestamp))))
      (puthash (chat-subagent-id subagent) subagent chat-subagent--registry)
      (condition-case err
          (let ((summary (funcall runner child-session)))
            (setf (chat-subagent-summary subagent) summary
                  (chat-subagent-status subagent) 'completed
                  (chat-subagent-ended-at subagent)
                  (chat-subagent--timestamp))
            subagent)
        (error
         (setf (chat-subagent-summary subagent) (error-message-string err)
               (chat-subagent-status subagent) 'failed
               (chat-subagent-ended-at subagent)
               (chat-subagent--timestamp))
         subagent)))))

(defun chat-subagent-start-agent
    (name prompt parent-session success error-callback &optional budget)
  "Start nested agent NAME for PROMPT and report through callbacks."
  (let* ((depth (1+ (chat-subagent--session-depth parent-session)))
         (_ (chat-subagent--ensure-depth depth))
         (message
          (make-chat-message
           :id (chat-session-new-message-id "subagent-user")
           :role :user
           :content prompt
           :timestamp (current-time)))
         (child-session
          (chat-subagent--child-session
           name (list message) parent-session depth))
         (subagent
          (make-chat-subagent
           :id (chat-subagent--id)
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
    (chat-session-save child-session)
    (condition-case err
        (setq
         run
         (chat-agent-start
          (list
       :model (chat-session-model-id child-session)
       :messages (list message)
       :session child-session
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
             (setf (chat-subagent-status subagent) status
                   (chat-subagent-summary subagent) content
                   (chat-subagent-ended-at subagent)
                   (chat-subagent--timestamp))
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
         (setf (chat-subagent-status subagent) 'failed
               (chat-subagent-summary subagent) message
               (chat-subagent-ended-at subagent)
               (chat-subagent--timestamp))
         (funcall error-callback message))))
    (setf (chat-subagent-run subagent) run)
    (list :cancel
          (lambda ()
            (when (and run (chat-agent-active-p run))
              (chat-agent-cancel run))))))

(defun chat-subagent-start-external (name command input-jsonl log-file
                                          &optional depth budget)
  "Start external subprocess-agent NAME using COMMAND.
INPUT-JSONL is written to the subprocess stdin when non-nil.  Output is
captured in LOG-FILE."
  (let ((depth (or depth 0)))
    (chat-subagent--ensure-depth depth)
    (make-directory (file-name-directory log-file) t)
    (let* ((subagent (make-chat-subagent
                      :id (chat-subagent--id)
                      :kind 'external
                      :name name
                      :status 'running
                      :depth depth
                      :budget (or budget chat-subagent-default-budget)
                      :log-file log-file
                      :started-at (chat-subagent--timestamp)))
           proc)
      (with-temp-file log-file)
      (setq proc
            (make-process
             :name (concat "chat-subagent-" (chat-subagent-id subagent))
             :buffer nil
             :command command
             :connection-type 'pipe
             :noquery t
             :filter (lambda (_proc chunk)
                       (write-region chunk nil log-file 'append 'silent))
             :sentinel (lambda (process _event)
                         (unless (process-live-p process)
                           (unless (eq (chat-subagent-status subagent)
                                       'cancelled)
                             (setf (chat-subagent-status subagent)
                                   (if (zerop (process-exit-status process))
                                       'completed
                                     'failed)
                                   (chat-subagent-summary subagent)
                                   (chat-subagent--external-summary log-file)
                                   (chat-subagent-ended-at subagent)
                                   (chat-subagent--timestamp)))))))
      (setf (chat-subagent-process subagent) proc)
      (puthash (chat-subagent-id subagent) subagent chat-subagent--registry)
      (when input-jsonl
        (process-send-string proc input-jsonl))
      (process-send-eof proc)
      subagent)))

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
                   "\n"))
           (subagent
            (chat-subagent-start-external
             name command input log-file 0 budget)))
      (remhash (chat-subagent-id subagent) chat-subagent--registry)
      (setf (chat-subagent-id subagent) id)
      (puthash id subagent chat-subagent--registry)
      (chat-subagent-describe id))))

(defun chat-subagent-cancel (id)
  "Cancel sub-agent ID."
  (let ((subagent (gethash id chat-subagent--registry)))
    (unless subagent
      (error "Sub-agent not found: %s" id))
    (setf (chat-subagent-status subagent) 'cancelled
          (chat-subagent-ended-at subagent) (chat-subagent--timestamp))
    (when-let ((run (chat-subagent-run subagent)))
      (when (chat-agent-active-p run)
        (chat-agent-cancel run)))
    (when-let ((proc (chat-subagent-process subagent)))
      (when (process-live-p proc)
        (delete-process proc)))
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
