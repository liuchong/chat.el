;;; chat-agent-wire.el --- Agent events as session records -*- lexical-binding: t; -*-

;;; Commentary:

;; Turns an agent event into something a file can hold.
;;
;; An event cannot be written as it stands.  `chat-agent--emit' puts the run
;; on every one, the run holds the session, and the session holds the whole
;; conversation -- so an event is, transitively, the entire history, and
;; printing one wrote 1.4MB.  Seventy-seven of those made 90% of a 119MB log.
;;
;; So each kind is projected by hand into facts: counts, identifiers, sizes,
;; statuses.  Where content is the point, this records where the content is
;; rather than the content, since the context stream already holds it under
;; the same message id.
;;
;; Projected by hand and not generically because the compiler cannot tell a
;; short status string from a 300KB tool result, and a generic rule would
;; have to guess.  A test asserts every kind `chat-agent--emit' can produce
;; is projected here, so adding an event type without a projection fails the
;; suite rather than silently going unrecorded.

;;; Code:

(require 'cl-lib)
(require 'chat-event)
(require 'chat-agent-profile)

(declare-function chat-agent-run-state-session "chat-agent-types" (run))
(declare-function chat-agent-run-state-provider "chat-agent-types" (run))
(declare-function chat-agent-run-state-model "chat-agent-types" (run))
(declare-function chat-agent-run-state-transport "chat-agent-types" (run))
(declare-function chat-agent-run-state-max-steps "chat-agent-types" (run))
(declare-function chat-agent-run-state-messages "chat-agent-types" (run))
(declare-function chat-agent-run-state-profile "chat-agent-types" (run))
(declare-function chat-agent-run-execution-session "chat-agent-types" (run))
(declare-function chat-session-id "chat-session" (session))
(declare-function chat-session-p "chat-session" (object))
(declare-function chat-message-p "chat-session" (object))
(declare-function chat-message-id "chat-session" (message))
(declare-function chat-message-role "chat-session" (message))
(declare-function chat-message-content "chat-session" (message))
(declare-function chat-message-tool-calls "chat-session" (message))
(declare-function chat-message-tool-results "chat-session" (message))

(defconst chat-agent-wire-text-limit 200
  "Characters of a short text field kept verbatim in a record.

Error messages and tool summaries are worth reading in the stream; a
truncated tool result is not, and the context stream has all of it.")

(defun chat-agent-wire--chars (value)
  "Return the length of VALUE if it is a string, else nil."
  (and (stringp value) (length value)))

(defun chat-agent-wire--short (value)
  "Return VALUE bounded to `chat-agent-wire-text-limit' characters."
  (when (stringp value)
    (if (<= (length value) chat-agent-wire-text-limit)
        value
      (substring value 0 chat-agent-wire-text-limit))))

(defun chat-agent-wire--name (value)
  "Return VALUE as a string if it names something, else nil."
  (cond ((stringp value) value)
        ((and value (symbolp value)) (symbol-name value))
        (t nil)))

(defun chat-agent-wire--message-facts (message)
  "Return what is worth recording about MESSAGE, without its content."
  (when (chat-message-p message)
    (list (cons 'message_id (chat-message-id message))
          (cons 'role (chat-agent-wire--name (chat-message-role message)))
          (cons 'chars (or (chat-agent-wire--chars
                            (chat-message-content message))
                           0))
          (cons 'tool_calls (length (chat-message-tool-calls message)))
          (cons 'tool_results (length (chat-message-tool-results message))))))

(defun chat-agent-wire--tool-event-facts (event)
  "Return what is worth recording about the inner tool EVENT."
  (list (cons 'tool_event (chat-agent-wire--name (plist-get event :type)))
        (cons 'tool (chat-agent-wire--name (plist-get event :tool)))
        (cons 'index (plist-get event :index))
        (cons 'decision (chat-agent-wire--name (plist-get event :decision)))
        (cons 'arguments_chars (chat-agent-wire--chars
                                (plist-get event :arguments)))
        (cons 'summary_chars (chat-agent-wire--chars
                              (plist-get event :result-summary)))
        (cons 'summary (chat-agent-wire--short
                        (plist-get event :result-summary)))))

(defun chat-agent-wire-payload (event)
  "Return a bounded alist of facts about EVENT, or nil for no facts.

Every kind `chat-agent--emit' produces has a branch.  There is no
catch-all: an unprojected kind should fail a test, not reach a file as
whatever shape it happened to have.

Total, over every event any part of the program can hand it, including
malformed ones.  An observer that can raise is an observer that can turn
a run that worked into a run that failed while being watched."
  (let ((run (plist-get event :run)))
    (pcase (plist-get event :type)
      ('agent-start
       (when run
         (list (cons 'provider (chat-agent-wire--name
                                (chat-agent-run-state-provider run)))
               (cons 'model (chat-agent-run-state-model run))
               (cons 'transport (chat-agent-wire--name
                                 (chat-agent-run-state-transport run)))
               (cons 'max_steps (chat-agent-run-state-max-steps run))
               (cons 'message_count
                     (length (chat-agent-run-state-messages run))))))
      ('profile-resolved
       (chat-agent-profile-snapshot
        (plist-get event :profile)
        (and run (chat-agent-run-execution-session run))))
      ('model-request-started
       (list (cons 'provider (chat-agent-wire--name
                              (plist-get event :provider)))
             (cons 'model (chat-agent-wire--short
                           (plist-get event :model)))
             (cons 'request_id (chat-agent-wire--short
                                (plist-get event :request-id)))))
      ('context-transformed
       (list (cons 'message_count (plist-get event :message-count))))
      ('context-bundle
       (list (cons 'digest (chat-agent-wire--short
                            (plist-get event :digest)))
             (cons 'selected_count (plist-get event :selected-count))
             (cons 'omitted_count (plist-get event :omitted-count))))
      ;; The turn's start time, which is what makes the delay before the
      ;; first chunk a subtraction between two records rather than a
      ;; number someone has to remember to measure.
      ('turn-start nil)
      ('turn-ended
       (list (cons 'status (chat-agent-wire--name
                            (plist-get event :status)))
             (cons 'reason (chat-agent-wire--short
                            (plist-get event :reason)))))
      ('turn-failed
       (list (cons 'status (chat-agent-wire--name
                            (plist-get event :status)))
             (cons 'reason (chat-agent-wire--short
                            (plist-get event :reason)))))
      ('stream-chunk
       (list (cons 'delta_chars (chat-agent-wire--chars
                                 (plist-get event :text)))
             (cons 'chars (chat-agent-wire--chars
                           (plist-get event :content)))))
      ('stream-reasoning
       (list (cons 'delta_chars (chat-agent-wire--chars
                                 (plist-get event :text)))
             (cons 'chars (chat-agent-wire--chars
                           (plist-get event :reasoning)))))
      ('stream-result
       (list (cons 'chars (chat-agent-wire--chars (plist-get event :content)))
             (cons 'reasoning_chars (chat-agent-wire--chars
                                     (plist-get event :reasoning)))))
      ('model-tool-call-delta
       (let ((delta (plist-get event :delta)))
         (list (cons 'index (plist-get delta :index))
               (cons 'id (chat-agent-wire--short (plist-get delta :id)))
               (cons 'name (chat-agent-wire--short (plist-get delta :name)))
               (cons 'arguments_chars
                     (chat-agent-wire--chars
                      (or (plist-get delta :arguments-delta)
                          (plist-get delta :arguments)))))))
      ('model-usage
       (let ((usage (plist-get event :usage)))
         (list (cons 'input_tokens (plist-get usage :input-tokens))
               (cons 'output_tokens (plist-get usage :output-tokens))
               (cons 'total_tokens (plist-get usage :total-tokens))
               (cons 'cache_read_tokens
                     (plist-get usage :cache-read-tokens))
               (cons 'cache_write_tokens
                     (plist-get usage :cache-write-tokens)))))
      ('model-retry
       (list (cons 'attempt (plist-get event :attempt))
             (cons 'delay_seconds (plist-get event :delay-seconds))
             (cons 'message (chat-agent-wire--short
                             (plist-get event :message)))))
      ('tool-batch-start
       (list (cons 'count (plist-get event :count))))
      ('tool-event
       (chat-agent-wire--tool-event-facts (plist-get event :event)))
      ('tool-batch-end
       (list (cons 'count (plist-get event :count))
             (cons 'cancelled (and (plist-get event :cancelled) t))))
      ('message-appended
       (chat-agent-wire--message-facts (plist-get event :message)))
      ('truncated
       (list (cons 'count (plist-get event :count))))
      ('response
       (let ((processed (plist-get event :processed)))
         (list (cons 'chars (chat-agent-wire--chars
                             (plist-get processed :content)))
               (cons 'tool_calls (length (plist-get processed :tool-calls)))
               (cons 'parse_error (and (plist-get processed :parse-error) t)))))
      ('followup
       (chat-agent-wire--message-facts (plist-get event :message)))
      ;; What the reader wants here is which inputs were taken into which
      ;; step, because that is the question a steered run raises: the user
      ;; sent four things and got one answer, and this says where they went.
      ('steering
       (let ((messages (plist-get event :messages)))
         (list (cons 'count (length messages))
               (cons 'message_ids
                     (delq nil (mapcar (lambda (message)
                                         (and (chat-message-p message)
                                              (chat-message-id message)))
                                       messages))))))
      ('prepared-next-turn
       (list (cons 'count (length (plist-get event :messages)))))
      ('work-plan-finalization
       (list (cons 'action (chat-agent-wire--name
                            (plist-get event :action)))
             (cons 'attempt (plist-get event :attempt))
             (cons 'plan_id (chat-agent-wire--short
                             (plist-get event :plan-id)))
             (cons 'revision (plist-get event :revision))
             (cons 'status (chat-agent-wire--name
                            (plist-get event :status)))))
      ('error
       (list (cons 'message (chat-agent-wire--short
                             (plist-get event :message)))))
      ('agent-end
       (list (cons 'status (chat-agent-wire--name (plist-get event :status)))
             (cons 'reason (chat-agent-wire--short (plist-get event :reason)))
             (cons 'chars (chat-agent-wire--chars (plist-get event :content)))
             (cons 'tool_calls (length (plist-get event :tool-calls)))
             (cons 'tool_results (length (plist-get event :tool-results)))))
      (_ 'unprojected))))

(defun chat-agent-wire--session-id (event)
  "Return the session id EVENT belongs to, or nil."
  (when-let* ((run (plist-get event :run))
              (session (chat-agent-run-state-session run)))
    (and (chat-session-p session) (chat-session-id session))))

(defun chat-agent-wire-observe (event)
  "Project agent EVENT and publish it through the runtime event bus."
  (when-let ((session-id (chat-agent-wire--session-id event)))
    (let ((payload (chat-agent-wire-payload event)))
      (unless (eq payload 'unprojected)
        (chat-event-publish
         (chat-event-create
          :type (plist-get event :type)
          :session-id session-id
          :turn-id (plist-get event :turn)
          :source 'agent
          ;; Nils dropped rather than written: a record saying a field was
          ;; absent costs bytes on every event to say nothing.
          :payload (cl-remove-if (lambda (pair) (null (cdr pair))) payload)
          :context
          (delq nil
                (list (when-let ((step (plist-get event :step)))
                        (cons 'step step))))))))))

;;;###autoload
(defun chat-agent-wire-install ()
  "Record every agent event in its session's event stream."
  (add-hook 'chat-agent-event-functions #'chat-agent-wire-observe))

(provide 'chat-agent-wire)
;;; chat-agent-wire.el ends here
