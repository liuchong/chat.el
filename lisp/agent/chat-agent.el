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
(require 'chat-llm)

(defun chat-agent-active-p (run)
  "Return non-nil while RUN is still in flight."
  (and (chat-agent-run-state-p run)
       (not (chat-agent-run-state-done run))))

(defun chat-agent-start (config)
  "Start an agent run from CONFIG and return the run state.

CONFIG is a plist with these keys:

  :model           provider symbol (required)
  :messages        initial list of chat-message structs (required)
  :session         session passed to tool execution
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
  (let ((run (chat-agent--run-create
              :model (plist-get config :model)
              :messages (plist-get config :messages)
              :session (plist-get config :session)
              :transport (or (plist-get config :transport) 'sync)
              :on-event (plist-get config :on-event)
              :should-stop-fn (plist-get config :should-stop-fn)
              :steering-fn (plist-get config :steering-fn)
              :followup-fn (plist-get config :followup-fn)
              :transform-context-fn (plist-get config :transform-context-fn)
              :prepare-next-turn-fn (plist-get config :prepare-next-turn-fn)
              :max-steps (or (plist-get config :max-steps)
                             chat-agent-max-steps)
              :request-options (plist-get config :request-options)
              :followup-request-options
              (plist-get config :followup-request-options)
              :queue-mode (or (plist-get config :queue-mode) 'fifo)
              :native-tools (if (plist-member config :native-tools)
                                (plist-get config :native-tools)
                              chat-agent-native-tools))))
    (chat-agent--emit run 'agent-start)
    (chat-agent--turn run)
    run))

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
The message takes effect after the current tool batch."
  (when (and (chat-agent-run-state-p run) message)
    (chat-agent--queue-message
     run 'steering message)
    message))

(defun chat-agent-follow-up (run message)
  "Queue MESSAGE to run only after RUN would otherwise stop."
  (when (and (chat-agent-run-state-p run) message)
    (chat-agent--queue-message
     run 'followup message)
    message))

(provide 'chat-agent)
;;; chat-agent.el ends here
