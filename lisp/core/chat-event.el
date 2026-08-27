;;; chat-event.el --- Agent runtime lifecycle events -*- lexical-binding: t; -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;;; Commentary:

;; One runtime contract for facts that happen around a session.  Producers
;; publish typed events; synchronous blockers may stop the small set of
;; events that are declared blockable; observers can record or display an
;; event but cannot change the run.
;;
;; The existing session wire remains the durable store.  This module adds
;; identity, provenance and handler outcomes to its envelope instead of
;; creating another log with another reader.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'chat-log)
(require 'chat-session-wire)

(defconst chat-event-schema-version 1
  "Version of the in-memory lifecycle event contract.")

(defconst chat-event-lifecycle-types
  '(session-started session-ended
    turn-start turn-ended turn-failed
    user-prompt-submitted user-prompt-queued
    pre-tool post-tool
    permission-requested permission-resolved
    task-started task-ended
    subagent-started subagent-ended
    pre-compact post-compact)
  "Canonical lifecycle event types.

Other diagnostic event types may travel through the same bus.  This list
names the stable integration points extensions may rely on.")

(defcustom chat-event-blocking-types
  '(user-prompt-submitted pre-tool pre-compact)
  "Lifecycle event types whose blockers are run before publication."
  :type '(repeat symbol)
  :group 'chat)

(defcustom chat-event-failure-policies
  '((pre-tool . fail-closed)
    (pre-compact . fail-closed))
  "Failure policy for blockable lifecycle event types.

An omitted type is fail-open.  A policy applies only to a blocker error,
timeout or invalid return value; an explicit block always blocks."
  :type '(alist :key-type symbol
                :value-type (choice (const fail-open) (const fail-closed)))
  :group 'chat)

(defcustom chat-event-blocker-timeout 2.0
  "Seconds one lifecycle blocker may take, or nil for no timeout."
  :type '(choice (const :tag "No timeout" nil) number)
  :group 'chat)

(defcustom chat-event-reason-max-chars 1024
  "Maximum number of characters kept from a handler reason."
  :type 'integer
  :group 'chat)

(defvar chat-event-observer-functions nil
  "Functions called with each published `chat-event'.

Observer errors are diagnosed and ignored.  An observer is not an
authorization boundary and must never be able to change the run.")

(defvar chat-event-blocker-functions nil
  "Functions called for events in `chat-event-blocking-types'.

Each function receives a `chat-event' and returns nil, t, `allow',
`continue', or a plist with `:decision'.  Supported decisions are
`allow', `continue', `modify' and `block'.  A modify result may include
`:payload' and `:context'; a block result should include `:reason'.")

(defvar chat-event--id-sequence 0
  "Process-local suffix used to make event ids unique within a millisecond.")

(defconst chat-event--reserved-wire-context-keys
  '(event_id event_schema_version source turn_id task_id parent_id
    event_decision event_reason event_handler event_failure event_failures)
  "Wire envelope keys owned exclusively by the event runtime.")

(cl-defstruct (chat-event
               (:constructor chat-event-create)
               (:copier nil))
  "One versioned runtime lifecycle event."
  (schema-version chat-event-schema-version)
  id
  type
  timestamp-ms
  session-id
  turn-id
  task-id
  parent-id
  source
  payload
  ;; Live object blockers may inspect or replace.  Never persisted.
  subject
  context
  outcome)

(defun chat-event--timestamp-ms ()
  "Return the current Unix time in milliseconds."
  (round (* 1000 (float-time))))

(defun chat-event--new-id ()
  "Return a fresh process-unique event id."
  (format "event-%d-%d"
          (chat-event--timestamp-ms)
          (cl-incf chat-event--id-sequence)))

(defun chat-event--short-reason (reason)
  "Return REASON as bounded text, or nil."
  (when reason
    (truncate-string-to-width
     (if (stringp reason) reason (format "%s" reason))
     chat-event-reason-max-chars nil nil t)))

(defun chat-event--normalize (event)
  "Fill generated fields on EVENT and validate its contract."
  (unless (chat-event-p event)
    (error "Not a chat event: %S" event))
  (unless (symbolp (chat-event-type event))
    (error "Event type must be a symbol: %S" (chat-event-type event)))
  (unless (or (null (chat-event-session-id event))
              (stringp (chat-event-session-id event)))
    (error "Event session id must be a string or nil"))
  (unless (or (null (chat-event-payload event))
              (listp (chat-event-payload event)))
    (error "Event payload must be an alist or nil"))
  (unless (or (null (chat-event-context event))
              (listp (chat-event-context event)))
    (error "Event context must be an alist or nil"))
  (unless (chat-event-id event)
    (setf (chat-event-id event) (chat-event--new-id)))
  (unless (chat-event-timestamp-ms event)
    (setf (chat-event-timestamp-ms event) (chat-event--timestamp-ms)))
  (unless (chat-event-source event)
    (setf (chat-event-source event) 'runtime))
  event)

(defun chat-event-add-observer (function)
  "Register observer FUNCTION once, preserving registration order."
  (unless (memq function chat-event-observer-functions)
    (setq chat-event-observer-functions
          (append chat-event-observer-functions (list function))))
  function)

(defun chat-event-remove-observer (function)
  "Remove observer FUNCTION."
  (setq chat-event-observer-functions
        (delq function chat-event-observer-functions)))

(defun chat-event-add-blocker (function)
  "Register blocker FUNCTION once, preserving registration order."
  (unless (memq function chat-event-blocker-functions)
    (setq chat-event-blocker-functions
          (append chat-event-blocker-functions (list function))))
  function)

(defun chat-event-remove-blocker (function)
  "Remove blocker FUNCTION."
  (setq chat-event-blocker-functions
        (delq function chat-event-blocker-functions)))

(defun chat-event-blocking-p (event)
  "Return non-nil when EVENT admits synchronous blockers."
  (memq (chat-event-type event) chat-event-blocking-types))

(defun chat-event-failure-policy (event)
  "Return blocker failure policy for EVENT."
  (or (alist-get (chat-event-type event) chat-event-failure-policies)
      'fail-open))

(defun chat-event--call-blocker (function event)
  "Call blocker FUNCTION with EVENT and return its value or a failure plist."
  (condition-case err
      (if (and (numberp chat-event-blocker-timeout)
               (> chat-event-blocker-timeout 0))
          (with-timeout
              (chat-event-blocker-timeout
               (list :failure 'timeout
                     :reason (format "blocker timed out after %.3fs"
                                     chat-event-blocker-timeout)))
            (funcall function event))
        (funcall function event))
    (error
     (list :failure 'error :reason (error-message-string err)))))

(defun chat-event--valid-decision-p (result)
  "Return non-nil when RESULT is a supported blocker result."
  (or (null result)
      (eq result t)
      (memq result '(allow continue))
      (and (listp result)
           (memq (plist-get result :decision)
                 '(allow continue modify block)))))

(defun chat-event--apply-modification (event result)
  "Apply blocker RESULT to EVENT, returning nil or a failure plist.

Invalid replacements are rolled back so later persistence and observers
never receive a malformed event."
  (let ((payload (chat-event-payload event))
        (subject (chat-event-subject event))
        (context (chat-event-context event)))
    (condition-case err
        (progn
          (when (plist-member result :payload)
            (setf (chat-event-payload event) (plist-get result :payload)))
          (when (plist-member result :subject)
            (setf (chat-event-subject event) (plist-get result :subject)))
          (when (plist-member result :context)
            (setf (chat-event-context event) (plist-get result :context)))
          (unless (or (null (chat-event-payload event))
                      (listp (chat-event-payload event)))
            (error "Modified event payload must be an alist or nil"))
          (unless (or (null (chat-event-context event))
                      (listp (chat-event-context event)))
            (error "Modified event context must be an alist or nil"))
          nil)
      (error
       (setf (chat-event-payload event) payload
             (chat-event-subject event) subject
             (chat-event-context event) context)
       (list :failure 'invalid-modification
             :reason (error-message-string err))))))

(defun chat-event--failure-outcome (event function failure)
  "Return how EVENT treats blocker FUNCTION's FAILURE."
  (let ((closed (eq (chat-event-failure-policy event) 'fail-closed)))
    (list :decision (if closed 'block 'continue)
          :reason (chat-event--short-reason (plist-get failure :reason))
          :handler function
          :failure (plist-get failure :failure))))

(defun chat-event--run-blockers (event)
  "Run blockers for EVENT and return the final outcome plist."
  (let ((functions chat-event-blocker-functions)
        (failures nil)
        (blocked nil))
    (while (and functions (null blocked))
      (let* ((function (pop functions))
             (raw (chat-event--call-blocker function event))
             (failure
              (cond
               ((and (listp raw) (plist-get raw :failure)) raw)
               ((chat-event--valid-decision-p raw) nil)
               (t (list :failure 'invalid-result
                        :reason (format "invalid blocker result: %S" raw))))))
        (cond
         (failure
          (let ((outcome (chat-event--failure-outcome event function failure)))
            (if (eq (plist-get outcome :decision) 'block)
                (setq blocked outcome)
              (push outcome failures))))
         ((and (listp raw) (eq (plist-get raw :decision) 'block))
          (setq blocked
                (list :decision 'block
                      :reason (chat-event--short-reason
                               (plist-get raw :reason))
                      :handler function)))
         ((and (listp raw) (eq (plist-get raw :decision) 'modify))
          (when-let* ((failure (chat-event--apply-modification event raw)))
            (let ((outcome
                   (chat-event--failure-outcome event function failure)))
              (if (eq (plist-get outcome :decision) 'block)
                  (setq blocked outcome)
                (push outcome failures))))))))
    (or blocked
        (list :decision 'allow :failures (nreverse failures)))))

(defun chat-event-allowed-p (outcome)
  "Return non-nil when OUTCOME permits the lifecycle action."
  (not (eq (plist-get outcome :decision) 'block)))

(defun chat-event--wire-context (event)
  "Return EVENT metadata for the session wire envelope."
  (let ((outcome (chat-event-outcome event))
        (producer-context
         (seq-remove
          (lambda (entry)
            (let ((key (car-safe entry)))
              (memq (if (stringp key) (intern-soft key) key)
                    chat-event--reserved-wire-context-keys)))
          (chat-event-context event))))
    (delq
     nil
     (append
      (list (cons 'event_id (chat-event-id event))
            (cons 'event_schema_version (chat-event-schema-version event))
            (cons 'source (format "%s" (chat-event-source event)))
            (when (chat-event-turn-id event)
              (cons 'turn_id (chat-event-turn-id event)))
            (when (chat-event-task-id event)
              (cons 'task_id (chat-event-task-id event)))
            (when (chat-event-parent-id event)
              (cons 'parent_id (chat-event-parent-id event))))
      producer-context
      (when outcome
        (list
         (cons 'event_decision
               (format "%s" (plist-get outcome :decision)))
         (when-let* ((reason (plist-get outcome :reason)))
           (cons 'event_reason reason))
         (when-let* ((handler (plist-get outcome :handler)))
           (cons 'event_handler (format "%s" handler)))
         (when-let* ((failure (plist-get outcome :failure)))
           (cons 'event_failure (format "%s" failure)))
         (when-let* ((failures (plist-get outcome :failures)))
           (cons
            'event_failures
            (mapcar
             (lambda (item)
               (delq nil
                     (list
                      (cons 'handler (format "%s" (plist-get item :handler)))
                      (cons 'failure (format "%s" (plist-get item :failure)))
                      (when-let* ((reason (plist-get item :reason)))
                        (cons 'reason reason)))))
             failures)))))))))

(defun chat-event--persist (event)
  "Append EVENT to its session wire when it has a session id."
  (when-let* ((session-id (chat-event-session-id event)))
    (chat-session-wire-record
     session-id
     (chat-event-type event)
     (chat-event-payload event)
     (chat-event--wire-context event))))

(defun chat-event--notify-observers (event)
  "Notify observers about EVENT without allowing them to affect the run."
  (dolist (observer chat-event-observer-functions)
    (condition-case err
        (funcall observer event)
      (error
       (chat-log "[EVENT] Observer %s failed for %s: %s"
                 observer (chat-event-type event)
                 (error-message-string err))))))

(defun chat-event-publish (event)
  "Publish EVENT and return its authorization outcome.

Blockers run only for types in `chat-event-blocking-types'.  Persistence
and observers see the final payload and outcome."
  (chat-event--normalize event)
  (setf (chat-event-outcome event)
        (if (chat-event-blocking-p event)
            (chat-event--run-blockers event)
          (list :decision 'observe)))
  (chat-event--persist event)
  (chat-event--notify-observers event)
  (chat-event-outcome event))

(cl-defun chat-event-emit
    (type &key session-id turn-id task-id parent-id source payload subject context)
  "Create and publish one lifecycle event of TYPE.

The return value is the event's authorization outcome."
  (chat-event-publish
   (chat-event-create
    :type type
    :session-id session-id
    :turn-id turn-id
    :task-id task-id
    :parent-id parent-id
    :source source
    :payload payload
    :subject subject
    :context context)))

(provide 'chat-event)
;;; chat-event.el ends here
