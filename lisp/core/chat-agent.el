;;; chat-agent.el --- Event-driven agent run loop -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;; Author: chat.el contributors
;; Keywords: chat, agent, tools

;; This file is not part of GNU Emacs.

;;; Commentary:

;; This module provides a UI agnostic agent run loop.
;; A run sends messages to a model, executes requested tool calls,
;; feeds results back, and repeats until the model answers, the step
;; limit is reached, or the run is cancelled.
;;
;; All progress is reported through a single event callback.
;; Views subscribe with :on-event and react to event plists:
;;
;;   agent-start               the run was created
;;   turn-start                a new request is about to be sent
;;   stream-chunk              a streaming chunk arrived (:text :content)
;;   tool-event                a tool pipeline event (:event)
;;   truncated                 a truncated response had its tool calls refused
;;   response                  a response was processed (:processed)
;;   followup                  a follow-up message was queued (:message)
;;   steering                  steering messages were injected (:messages)
;;   error                     a transport or processing error (:message)
;;   agent-end                 the run finished (:status :reason ...)
;;
;; Loop design follows the pi agent-loop: stop conditions and steering
;; are callbacks, truncated responses refuse their tool calls, and the
;; event stream is the only output channel.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'chat-session)
(require 'chat-tool-caller)
(require 'chat-llm)
(require 'chat-stream)

;; ------------------------------------------------------------------
;; Customization
;; ------------------------------------------------------------------

(defcustom chat-agent-max-steps 100
  "Maximum number of agent loop steps per run."
  :type 'integer
  :group 'chat)

(defconst chat-agent-truncated-tool-result-text
  (concat
   "Tool call rejected: the model response was truncated, so the tool "
   "call arguments may be incomplete. Re-issue the tool call.")
  "Synthetic tool result used when a truncated response is refused.")

;; ------------------------------------------------------------------
;; Run state
;; ------------------------------------------------------------------

(cl-defstruct (chat-agent-run-state
               (:constructor chat-agent--run-create)
               (:copier nil))
  model messages session transport on-event should-stop-fn steering-fn
  followup-fn max-steps request-options
  (step 0)
  content tool-events tool-calls tool-results
  raw-request raw-response
  handle cancelled done status reason)

;; ------------------------------------------------------------------
;; Public API
;; ------------------------------------------------------------------

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
  :request-options extra plist passed to the transport

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
              :request-options (plist-get config :request-options))))
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

;; ------------------------------------------------------------------
;; Loop driver
;; ------------------------------------------------------------------

(defun chat-agent--emit (run type &rest props)
  "Deliver an event of TYPE with PROPS to the RUN event callback."
  (when-let ((on-event (chat-agent-run-state-on-event run)))
    (condition-case nil
        (funcall on-event
                 (append (list :type type
                               :step (chat-agent-run-state-step run)
                               :run run)
                         props))
      (error nil))))

(defun chat-agent--turn (run)
  "Run one agent turn for RUN."
  (cond
   ((chat-agent-run-state-cancelled run)
    (chat-agent--finish run 'cancelled nil))
   ((>= (chat-agent-run-state-step run)
        (chat-agent-run-state-max-steps run))
    (chat-agent--finish run 'stopped 'max-steps))
   (t
    (setf (chat-agent-run-state-step run)
          (1+ (chat-agent-run-state-step run)))
    (chat-agent--apply-steering run)
    (chat-agent--emit run 'turn-start)
    (chat-agent--dispatch run))))

(defun chat-agent--apply-steering (run)
  "Append steering messages to RUN when the steering callback has any."
  (when-let ((fn (chat-agent-run-state-steering-fn run)))
    (let ((extra (funcall fn run)))
      (when extra
        (setf (chat-agent-run-state-messages run)
              (append (chat-agent-run-state-messages run) extra))
        (chat-agent--emit run 'steering :messages extra)))))

(defun chat-agent--stop-p (run processed)
  "Return non-nil when RUN should stop after PROCESSED."
  (if-let ((fn (chat-agent-run-state-should-stop-fn run)))
      (funcall fn run processed)
    (and (null (plist-get processed :tool-calls))
         (not (plist-get processed :parse-error)))))

(defun chat-agent--finish (run status reason)
  "Finish RUN once with STATUS and REASON and emit the final event."
  (unless (chat-agent-run-state-done run)
    (setf (chat-agent-run-state-done run) t
          (chat-agent-run-state-status run) status
          (chat-agent-run-state-reason run) reason)
    (chat-agent--emit
     run 'agent-end
     :status status
     :reason reason
     :content (chat-agent-run-state-content run)
     :tool-calls (chat-agent-run-state-tool-calls run)
     :tool-results (chat-agent-run-state-tool-results run)
     :tool-events (chat-agent-run-state-tool-events run)
     :raw-request (chat-agent-run-state-raw-request run)
     :raw-response (chat-agent-run-state-raw-response run)
     :steps (chat-agent-run-state-step run))))

;; ------------------------------------------------------------------
;; Transports
;; ------------------------------------------------------------------

(defun chat-agent--dispatch (run)
  "Send the current RUN messages through the configured transport."
  (condition-case err
      (if (eq (chat-agent-run-state-transport run) 'stream)
          (chat-agent--dispatch-stream run)
        (chat-agent--dispatch-sync run))
    (error
     (chat-agent--emit run 'error :message (error-message-string err))
     (chat-agent--finish run 'error (error-message-string err)))))

(defun chat-agent--dispatch-sync (run)
  "Dispatch RUN through the request-response transport."
  (setf (chat-agent-run-state-handle run)
        (chat-llm-request-async
         (chat-agent-run-state-model run)
         (chat-agent-run-state-messages run)
         (lambda (result)
           (unless (chat-agent-run-state-cancelled run)
             (chat-agent--handle-result run result)))
         (lambda (err-message)
           (unless (chat-agent-run-state-cancelled run)
             (chat-agent--emit run 'error :message err-message)
             (chat-agent--finish run 'error err-message)))
         (chat-agent-run-state-request-options run))))

(defun chat-agent--dispatch-stream (run)
  "Dispatch RUN through the streaming transport."
  (let ((content-acc ""))
    (let ((proc
           (chat-stream-request
            (chat-agent-run-state-model run)
            (chat-agent-run-state-messages run)
            (lambda (chunk)
              (when (and chunk (> (length chunk) 0))
                (setq content-acc (concat content-acc chunk))
                (chat-agent--emit run 'stream-chunk
                                  :text chunk
                                  :content content-acc)))
            (append (list :stream t)
                    (chat-agent-run-state-request-options run)))))
      (setf (chat-agent-run-state-handle run) proc)
      (let ((inner (process-sentinel proc)))
        (set-process-sentinel
         proc
         (lambda (p event)
           (when (and inner (not (chat-agent-run-state-cancelled run)))
             (condition-case nil
                 (funcall inner p event)
               (error nil)))
           (cond
            ((chat-agent-run-state-cancelled run)
             nil)
            ((string-match-p "finished\\|exited" event)
             (chat-agent--handle-result
              run (list :content content-acc
                        :raw-request nil
                        :raw-response nil)))
            ((string-match-p "failed\\|killed\\|deleted" event)
             (chat-agent--emit run 'error :message (string-trim event))
             (chat-agent--finish run 'error (string-trim event))))))))))

;; ------------------------------------------------------------------
;; Response handling
;; ------------------------------------------------------------------

(defun chat-agent--handle-result (run result)
  "Process transport RESULT for RUN and continue or finish the loop."
  (setf (chat-agent-run-state-raw-request run) (plist-get result :raw-request)
        (chat-agent-run-state-raw-response run) (plist-get result :raw-response))
  (let* ((content (or (plist-get result :content) ""))
         (truncated-calls
          ;; A response cut short by the output limit may hold damaged
          ;; tool call JSON, so its calls are refused before execution.
          (and (equal (plist-get result :finish-reason) "length")
               (chat-tool-caller-parse content)))
         (processed
          (if truncated-calls
              (list :content (string-trim-right
                              (chat-tool-caller-extract-content content))
                    :tool-calls truncated-calls
                    :tool-results (mapcar
                                   (lambda (_call)
                                     chat-agent-truncated-tool-result-text)
                                   truncated-calls)
                    :tool-events nil
                    :parse-error nil
                    :truncated-tool-calls t)
            (chat-tool-caller-process-response-data
             content
             (chat-agent-run-state-session run)
             (lambda (event)
               (chat-agent--emit run 'tool-event :event event))))))
    (when truncated-calls
      (chat-agent--emit run 'truncated :count (length truncated-calls))
      (dolist (call truncated-calls)
        (chat-agent--emit run 'tool-event
                          :event (list :type 'tool-error
                                       :tool (plist-get call :name)
                                       :result-summary
                                       chat-agent-truncated-tool-result-text))))
    (setf (chat-agent-run-state-content run) (plist-get processed :content)
          (chat-agent-run-state-tool-calls run)
          (append (chat-agent-run-state-tool-calls run)
                  (plist-get processed :tool-calls))
          (chat-agent-run-state-tool-results run)
          (append (chat-agent-run-state-tool-results run)
                  (plist-get processed :tool-results))
          (chat-agent-run-state-tool-events run)
          (append (chat-agent-run-state-tool-events run)
                  (plist-get processed :tool-events)))
    (chat-agent--emit run 'response :processed processed)
    (if (chat-agent--stop-p run processed)
        (chat-agent--finish run 'completed nil)
      (chat-agent--queue-followup run processed)
      (chat-agent--turn run))))

(defun chat-agent--queue-followup (run processed)
  "Queue the follow-up message for PROCESSED onto the RUN messages."
  (let* ((text (if-let ((fn (chat-agent-run-state-followup-fn run)))
                   (funcall fn processed)
                 (chat-agent--default-followup-text processed)))
         (message (make-chat-message
                   :id (chat-session-new-message-id
                        (format "agent-step-%d" (chat-agent-run-state-step run)))
                   :role :system
                   :content text
                   :timestamp (current-time))))
    (setf (chat-agent-run-state-messages run)
          (append (chat-agent-run-state-messages run) (list message)))
    (chat-agent--emit run 'followup :message message)))

(defun chat-agent--tool-result-lines (tool-calls tool-results)
  "Format TOOL-CALLS and TOOL-RESULTS into readable lines."
  (let (lines)
    (while (and tool-calls tool-results)
      (let* ((call (car tool-calls))
             (name (plist-get call :name))
             (arguments (plist-get call :arguments))
             (result (chat-tool-caller-truncate-result
                      (string-trim-right (or (car tool-results) "")))))
        (push (format "- %s %S => %s" name arguments result) lines))
      (setq tool-calls (cdr tool-calls))
      (setq tool-results (cdr tool-results)))
    (nreverse lines)))

(defun chat-agent--default-followup-text (processed)
  "Build the default follow-up text for PROCESSED."
  (if (and (null (plist-get processed :tool-calls))
           (plist-get processed :parse-error))
      chat-tool-caller-parse-error-followup-text
    (concat
     "Tool results from the previous step:\n"
     (mapconcat #'identity
                (chat-agent--tool-result-lines
                 (plist-get processed :tool-calls)
                 (plist-get processed :tool-results))
                "\n")
     "\nUse these results to continue helping.\n"
     "If a tool result says approval denied, do not retry the same risky tool immediately.\n"
     "If another tool is needed, call one tool as JSON.\n"
     "Otherwise answer normally.")))

(provide 'chat-agent)
;;; chat-agent.el ends here
