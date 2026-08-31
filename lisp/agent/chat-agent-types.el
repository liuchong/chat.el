;;; chat-agent-types.el --- Agent kernel types and contracts -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;;; Commentary:

;; Types for the agent kernel.  The loop works with
;; `chat-message' throughout.  Provider payloads are produced only at
;; the LLM boundary by `chat-llm--format-messages' (convertToLlm).
;;
;; Event types delivered through :on-event:
;;
;;   agent-start  profile-resolved  context-transformed  context-bundle
;;   turn-start  turn-ended  turn-failed  model-request-started
;;   stream-chunk
;;   stream-reasoning  stream-result  model-tool-call-delta  model-usage
;;   model-retry
;;   tool-batch-start  tool-event  tool-batch-end
;;   message-appended  truncated  response  followup  steering
;;   prepared-next-turn  work-plan-finalization  error  agent-end
;;
;; `agent-end' :status is one of completed, stopped, error, cancelled.

;;; Code:

(require 'cl-lib)
(require 'chat-agent-budget)
(require 'chat-llm)

(defcustom chat-agent-native-tools t
  "When non-nil, advertise tools through the provider tool-calling API."
  :type 'boolean
  :group 'chat)

(defcustom chat-agent-model-transport-retries 4
  "Maximum retries for a model transport failure before any payload arrives."
  :type 'integer
  :group 'chat)

(defcustom chat-agent-model-transport-retry-delays '(2 5 10 20)
  "Seconds to wait before successive model transport retries.

When `chat-agent-model-transport-retries' exceeds this list, the final delay is
reused.  Waiting is asynchronous and remains cancellable."
  :type '(repeat number)
  :group 'chat)

(defconst chat-agent-truncated-tool-result-text
  (concat
   "Tool call rejected: the model response was truncated, so the tool "
   "call arguments may be incomplete. Re-issue the tool call.")
  "Synthetic tool result used when a truncated response is refused.")

(cl-defstruct (chat-agent-run-state
               (:constructor chat-agent--run-create)
               (:copier nil))
  provider model messages session execution-session profile transport task-id run-id
  project-root context-target-path context-fragments last-context-bundle
  goal-projection-revision work-plan-projection-revision
  (work-plan-finalization-attempts 0)
  on-event should-stop-fn steering-fn
  followup-fn transform-context-fn prepare-next-turn-fn
  max-steps request-options followup-request-options
  ;; What a single input is worth, kept apart from `max-steps' so that a
  ;; later input can be given the same again.  Steering used to spend the
  ;; budget rather than bring any: a question that took six of eight steps
  ;; left the correction two, and the correction is usually the part the
  ;; user actually wanted.
  step-budget
  (step 0)
  ;; Which turn of the session this run answers.  Settled once, because
  ;; steering adds a user message mid-run and counting them again would
  ;; report the later steps of one turn as belonging to the next.
  turn
  turn-open
  content tool-events tool-calls tool-results
  raw-request raw-response
  handle cancelled done status reason
  (steering-queue nil)
  (followup-queue nil)
  (queue-mode 'fifo)
  (cancel-functions nil)
  read-set
  (native-tools t))

(defun chat-agent-run-execution-session (run)
  "Return RUN's transient policy session, or its original session."
  (or (chat-agent-run-state-execution-session run)
      (chat-agent-run-state-session run)))

(defun chat-agent-tool-call-id (call &optional _index)
  "Return the id of CALL, minting one when it arrived without.

Callers used to pass an index and get `call-<index>' back, which is safe
only while the whole turn is numbered by one loop.  It is minted instead,
so an id is a property of the call rather than of where it was standing
when someone asked."
  (or (plist-get call :id)
      (chat-llm-new-tool-call-id (plist-get call :name))))

(defun chat-agent-ensure-tool-call-ids (calls)
  "Return CALLS with an :id on every plist.

Every path that produces tool calls has to go through here.  The one that
did not -- `chat-tool-caller-process-response-data', which reads calls out
of the reply text -- wrote turns to disk with no ids at all, and each half
of the request then invented its own."
  (mapcar (lambda (call)
            (if (plist-get call :id)
                call
              (append (list :id (chat-agent-tool-call-id call)) call)))
          calls))

(provide 'chat-agent-types)
;;; chat-agent-types.el ends here
