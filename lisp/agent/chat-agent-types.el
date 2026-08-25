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
;;   agent-start  context-transformed  turn-start  stream-chunk
;;   stream-reasoning  stream-result  tool-batch-start  tool-event  tool-batch-end
;;   message-appended  truncated  response  followup  steering
;;   prepared-next-turn  error  agent-end
;;
;; `agent-end' :status is one of completed, stopped, error, cancelled.

;;; Code:

(require 'cl-lib)
(require 'chat-agent-budget)

(defcustom chat-agent-native-tools t
  "When non-nil, advertise tools through the provider tool-calling API."
  :type 'boolean
  :group 'chat)

(defconst chat-agent-truncated-tool-result-text
  (concat
   "Tool call rejected: the model response was truncated, so the tool "
   "call arguments may be incomplete. Re-issue the tool call.")
  "Synthetic tool result used when a truncated response is refused.")

(cl-defstruct (chat-agent-run-state
               (:constructor chat-agent--run-create)
               (:copier nil))
  model messages session transport on-event should-stop-fn steering-fn
  followup-fn transform-context-fn prepare-next-turn-fn
  max-steps request-options followup-request-options
  (step 0)
  content tool-events tool-calls tool-results
  raw-request raw-response
  handle cancelled done status reason
  (steering-queue nil)
  (followup-queue nil)
  (queue-mode 'fifo)
  (cancel-functions nil)
  (native-tools t))

(defun chat-agent-tool-call-id (call index)
  "Return a stable id for CALL, synthesizing one from INDEX when missing."
  (or (plist-get call :id)
      (format "call-%d" index)))

(defun chat-agent-ensure-tool-call-ids (calls)
  "Return CALLS with an :id on every plist."
  (let ((index 0)
        (out nil))
    (dolist (call calls)
      (setq index (1+ index))
      (push (if (plist-get call :id)
                call
              (append (list :id (chat-agent-tool-call-id call index)) call))
            out))
    (nreverse out)))

(provide 'chat-agent-types)
;;; chat-agent-types.el ends here
