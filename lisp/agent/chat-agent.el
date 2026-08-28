;;; chat-agent.el --- Stateful agent wrapper around the kernel loop -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;; Author: chat.el contributors
;; Keywords: chat, agent, tools

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Public API for the agent kernel.  The loop lives in
;; `chat-agent-loop'.  This file owns construction, cancellation,
;; steering, and follow-up queues.

;;; Code:

(require 'cl-lib)
(require 'chat-agent-types)
(require 'chat-agent-loop)
(require 'chat-agent-profile)
(require 'chat-llm)
(require 'chat-task)

(defun chat-agent-active-p (run)
  "Return non-nil while RUN is still in flight."
  (and (chat-agent-run-state-p run)
       (not (chat-agent-run-state-done run))))

(defun chat-agent--parent-task-id (session explicit-id)
  "Return a running parent task from EXPLICIT-ID or SESSION metadata."
  (let* ((metadata (and session (chat-session-metadata session)))
         (id (or explicit-id
                 (cdr (assoc 'activeTaskId metadata))
                 (cdr (assoc 'parentTaskId metadata))))
         (task (and id (chat-task-get id))))
    (and task (eq (chat-task-status task) 'running) id)))

(defun chat-agent--set-active-task-id (session id)
  "Set SESSION's transient active task marker to ID."
  (when session
    (let ((metadata (assq-delete-all
                     'activeTaskId
                     (copy-tree (chat-session-metadata session)))))
      (setf (chat-session-metadata session)
            (if id (cons (cons 'activeTaskId id) metadata) metadata)))))

(defun chat-agent--task-result (value)
  "Return VALUE bounded for durable task storage."
  (when value
    (truncate-string-to-width
     (if (stringp value) value (format "%S" value))
     8000 nil nil t)))

(defun chat-agent--finish-task (task event)
  "Finish tracked TASK from an agent-end EVENT."
  (unless (chat-task-terminal-p task)
    (let ((status (plist-get event :status))
          (content (chat-agent--task-result (plist-get event :content)))
          (reason (chat-agent--task-result (plist-get event :reason))))
      (pcase status
        ((or 'completed 'stopped)
         (chat-task-transition task 'completed :result content))
        ('cancelled
         (chat-task-transition task 'canceled :error reason))
        (_
         (chat-task-transition task 'failed
                               :error (or reason content "Agent failed")))))))

(defun chat-agent--create-task (config)
  "Create the foreground runtime task requested by CONFIG."
  (let* ((session (plist-get config :session))
         (model (plist-get config :model))
         (task
          (chat-task-adopt
           :id (or (plist-get config :task-id)
                   (chat-session-new-message-id "agent-task"))
           :parent-id
           (chat-agent--parent-task-id
            session (plist-get config :parent-task-id))
           :kind (or (plist-get config :task-kind) 'agent)
           :title (or (plist-get config :task-title)
                      (and session (chat-session-name session))
                      "Agent run")
           :status 'queued
           :session-id (and session (chat-session-id session))
           :source 'agent
           :payload
           `((model . ,(and model (symbol-name model)))
             (transport . ,(symbol-name
                            (or (plist-get config :transport) 'sync))))
           :metadata '((adapter . "agent"))
           :child-policy 'cancel)))
    (chat-task-transition task 'running)
    task))

(defun chat-agent-start (config)
  "Start an agent run from CONFIG and return the run state.

CONFIG is a plist with these keys:

  :model           provider symbol (required)
  :messages        initial list of chat-message structs (required)
  :session         session passed to tool execution
  :profile         optional agent profile id
  :project-root    root used for trusted project extension discovery
  :context-target-path
                   target path used for scoped context selection
  :context-fragments
                   typed standing context retained until request projection
  :track-task      non-nil records this run as a durable runtime task
  :task-id         optional stable id for the tracked task
  :parent-task-id  optional parent id for the tracked task
  :task-title      optional display title for the tracked task
  :task-kind       optional task kind, default `agent'
  :transport       `sync' (default) or `stream'
  :on-event        event callback (lambda (event))
  :should-stop-fn  optional stop predicate (lambda (run processed))
  :steering-fn     optional (lambda (run)) returning extra messages
  :followup-fn     optional (lambda (processed)) returning follow-up text
  :transform-context-fn
                   optional (lambda (run messages)) returning messages
                   for each step after pre-step hooks
  :prepare-next-turn-fn
                   optional (lambda (run processed)) returning messages
                   to append before any continued turn
  :queue-mode      `fifo' (default) or `lifo' for steering/follow-up queues
  :max-steps       step limit, default `chat-agent-max-steps'
  :native-tools    override `chat-agent-native-tools' for this run
  :request-options extra plist passed to the transport
  :followup-request-options
                   options merged over :request-options from the
                   second turn on, so follow-up requests can use a
                   different timeout or budget

Events are delivered synchronously through :on-event.  The final
`agent-end' event carries :status one of `completed', `stopped',
`error', or `cancelled', plus accumulated :content, :tool-calls,
:tool-results, :tool-events, :raw-request, :raw-response, and :steps."
  (setq config (chat-agent-profile-prepare-config config))
  (let* ((session (plist-get config :session))
         (previous-active-id
          (and session
               (cdr (assoc 'activeTaskId
                           (chat-session-metadata session)))))
         (task (and (plist-get config :track-task)
                    (chat-agent--create-task config)))
         (on-event (plist-get config :on-event))
         (run (chat-agent--run-create
              :model (plist-get config :model)
              :messages (plist-get config :messages)
              :session session
              :execution-session (plist-get config :execution-session)
              :profile (plist-get config :profile-resolved)
              :task-id (and task (chat-task-id task))
              :run-id (or (plist-get config :run-id)
                          (chat-session-new-message-id "agent-run"))
              :project-root (plist-get config :project-root)
              :context-target-path (plist-get config :context-target-path)
              :context-fragments (plist-get config :context-fragments)
              :transport (or (plist-get config :transport) 'sync)
              :on-event
              (lambda (event)
                (when (and task (eq (plist-get event :type) 'agent-end))
                  (chat-agent--finish-task task event)
                  (chat-agent--set-active-task-id
                   session previous-active-id))
                (when on-event
                  (funcall on-event event)))
              :should-stop-fn (plist-get config :should-stop-fn)
              :steering-fn (plist-get config :steering-fn)
              :followup-fn (plist-get config :followup-fn)
              :transform-context-fn (plist-get config :transform-context-fn)
              :prepare-next-turn-fn (plist-get config :prepare-next-turn-fn)
              :max-steps (or (plist-get config :max-steps)
                             chat-agent-max-steps)
              :step-budget (or (plist-get config :max-steps)
                               chat-agent-max-steps)
              :request-options (plist-get config :request-options)
              :followup-request-options
              (plist-get config :followup-request-options)
              :queue-mode (or (plist-get config :queue-mode) 'fifo)
              :read-set (make-hash-table :test 'equal)
              :native-tools (if (plist-member config :native-tools)
                                (plist-get config :native-tools)
                              chat-agent-native-tools))))
    (when task
      (chat-agent--set-active-task-id session (chat-task-id task))
      (setf (chat-task-cancel-function task)
            (lambda (_task _reason)
              (when (chat-agent-active-p run)
                (chat-agent-cancel run)))))
    (condition-case err
        (progn
          (chat-agent--emit run 'agent-start)
          (when (chat-agent-run-state-profile run)
            (chat-agent--emit run 'profile-resolved
                              :profile (chat-agent-run-state-profile run)))
          (chat-agent--turn run)
          run)
      (error
       (when (and task (not (chat-task-terminal-p task)))
         (chat-task-transition task 'failed
                               :error (error-message-string err)))
       (chat-agent--set-active-task-id session previous-active-id)
       (signal (car err) (cdr err))))))

(defun chat-agent-cancel (run)
  "Cancel RUN and return non-nil when a live run was cancelled."
  (when (chat-agent-active-p run)
    (setf (chat-agent-run-state-cancelled run) t)
    (dolist (fn (chat-agent-run-state-cancel-functions run))
      (ignore-errors (funcall fn run)))
    (let ((handle (chat-agent-run-state-handle run)))
      (cond
       ((and handle (buffer-live-p handle))
        (chat-llm-cancel-request handle))
       ((processp handle)
        (when (process-live-p handle)
          (delete-process handle)))))
    (chat-agent--finish run 'cancelled nil)
    t))

(defun chat-agent-add-cancel-function (run function)
  "Register FUNCTION to run when RUN is cancelled."
  (when (and (chat-agent-run-state-p run) (functionp function))
    (setf (chat-agent-run-state-cancel-functions run)
          (cons function (chat-agent-run-state-cancel-functions run)))
    function))

(defun chat-agent-clear-steering (run)
  "Clear queued steering messages for RUN."
  (when (chat-agent-run-state-p run)
    (setf (chat-agent-run-state-steering-queue run) nil)
    t))

(defun chat-agent-clear-follow-ups (run)
  "Clear queued follow-up messages for RUN."
  (when (chat-agent-run-state-p run)
    (setf (chat-agent-run-state-followup-queue run) nil)
    t))

(defun chat-agent-stop (run &optional reason)
  "Stop RUN without treating it as an error."
  (when (chat-agent-active-p run)
    (chat-agent--finish run 'stopped (or reason 'stopped))
    t))

(defun chat-agent--queue-message (run queue message)
  "Queue MESSAGE on RUN QUEUE respecting queue mode."
  (let* ((getter (pcase queue
                   ('steering #'chat-agent-run-state-steering-queue)
                   ('followup #'chat-agent-run-state-followup-queue)))
         (current (funcall getter run))
         (next (cons message current)))
    (pcase queue
      ('steering
       (setf (chat-agent-run-state-steering-queue run) next))
      ('followup
       (setf (chat-agent-run-state-followup-queue run) next)))))

(defun chat-agent-steer (run message)
  "Queue MESSAGE to be injected before the next LLM call of RUN.
The message takes effect after the current tool batch.

Also gives the run its budget back, counted from where it has got to, so
that the newest input has as many steps as the first one did.  Without
this, input arriving mid-run spends the budget instead of bringing any.

Unbounded on purpose: each refresh takes a human pressing return, and a
human is the exit from that loop.  A model cannot steer itself, so the
original limit still bounds a model going in circles."
  (when (and (chat-agent-run-state-p run) message)
    (chat-agent--queue-message run 'steering message)
    (when-let ((budget (chat-agent-run-state-step-budget run)))
      (setf (chat-agent-run-state-max-steps run)
            (+ (chat-agent-run-state-step run) budget)))
    message))

(defun chat-agent-follow-up (run message)
  "Queue MESSAGE to run only after RUN would otherwise stop."
  (when (and (chat-agent-run-state-p run) message)
    (chat-agent--queue-message
     run 'followup message)
    message))

(provide 'chat-agent)
;;; chat-agent.el ends here
