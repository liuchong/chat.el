;;; chat-agent.el --- Stateful agent wrapper around the kernel loop -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;; Author: chat.el contributors
;; Keywords: chat, agent, tools

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Public API for the PI-aligned agent kernel.  The loop lives in
;; `chat-agent-loop'.  This file owns construction, cancel, steering
;; and follow-up queues, matching PI's Agent class around agentLoop.

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
              :max-steps (or (plist-get config :max-steps)
                             chat-agent-max-steps)
              :request-options (plist-get config :request-options)
              :followup-request-options
              (plist-get config :followup-request-options)
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
    (let ((handle (chat-agent-run-state-handle run)))
      (cond
       ((and handle (buffer-live-p handle))
        (chat-llm-cancel-request handle))
       ((processp handle)
        (when (process-live-p handle)
          (delete-process handle)))))
    (chat-agent--finish run 'cancelled nil)
    t))

(defun chat-agent-steer (run message)
  "Queue MESSAGE to be injected before the next LLM call of RUN.
Like PI Agent.steer: takes effect after the current tool batch."
  (when (and (chat-agent-run-state-p run) message)
    (setf (chat-agent-run-state-steering-queue run)
          (cons message (chat-agent-run-state-steering-queue run)))
    message))

(defun chat-agent-follow-up (run message)
  "Queue MESSAGE to run only after RUN would otherwise stop.
Like PI Agent.followUp."
  (when (and (chat-agent-run-state-p run) message)
    (setf (chat-agent-run-state-followup-queue run)
          (cons message (chat-agent-run-state-followup-queue run)))
    message))

(provide 'chat-agent)
;;; chat-agent.el ends here
