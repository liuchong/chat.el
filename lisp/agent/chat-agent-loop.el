;;; chat-agent-loop.el --- Agent execution loop -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;;; Commentary:

;; Stateless-style loop driver for one agent run:
;;
;;   inner: steering -> LLM turn -> tools (or refuse if truncated)
;;   outer: follow-up queue after the agent would otherwise stop
;;
;; Native provider tool_calls are preferred.  JSON-in-text remains a
;; fallback.  Tool results are stored as :tool messages with
;; tool-call-id, not as system prose.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'chat-agent-types)
(require 'chat-log)
(require 'chat-session)
(require 'chat-transcript)
(require 'chat-context-budget)
(require 'chat-tool-caller)
(require 'chat-llm)
(require 'chat-stream)

(defvar chat-plugin-before-tool-call-functions nil)
(defvar chat-plugin-after-tool-call-functions nil)
(defvar chat-plugin-pre-step-functions nil)
(defvar chat-plugin-post-turn-functions nil)

(defvar chat-agent-event-functions nil
  "Functions called with every agent event, besides the run's own reader.

For observers that are not the run's caller: recording it, measuring it.
Each is called with the event and its errors are swallowed, because
watching a run must not be able to change what the run does.")

(defun chat-agent--emit (run type &rest props)
  "Deliver an event of TYPE with PROPS to the RUN event callback."
  (let ((event (append (list :type type
                             :step (chat-agent-run-state-step run)
                             :turn (chat-agent-run-state-turn run)
                             :run run)
                       props)))
    (when-let ((on-event (chat-agent-run-state-on-event run)))
      (condition-case nil (funcall on-event event) (error nil)))
    (dolist (observe chat-agent-event-functions)
      (condition-case nil (funcall observe event) (error nil)))))

(defun chat-agent--queue-order (run queue)
  "Return QUEUE in the delivery order configured for RUN."
  (if (eq (chat-agent-run-state-queue-mode run) 'lifo)
      queue
    (nreverse queue)))

(defun chat-agent--hook-until (hook &rest args)
  "Run HOOK functions with ARGS until one returns non-nil."
  (let ((result nil)
        (fns (symbol-value hook)))
    (while (and fns (null result))
      (setq result (apply (car fns) args)
            fns (cdr fns)))
    result))

(defun chat-agent--hook-all (hook &rest args)
  "Run every function on HOOK with ARGS."
  (dolist (fn (symbol-value hook))
    (apply fn args)))

(defun chat-agent--turn (run)
  "Run one agent turn for RUN."
  (cond
   ((chat-agent-run-state-cancelled run)
    (chat-agent--finish run 'cancelled nil))
   ((chat-agent-budget-exhausted-p
     (chat-agent-run-state-max-steps run)
     (chat-agent-run-state-step run))
    (chat-agent--finish run 'stopped 'max-steps))
   (t
    (setf (chat-agent-run-state-step run)
          (1+ (chat-agent-run-state-step run)))
    (chat-agent--apply-steering run)
    (chat-agent--hook-all 'chat-plugin-pre-step-functions run)
    (chat-log-timing-mark "steer")
    (chat-agent--transform-context run)
    (chat-log-timing-mark "transform")
    (chat-agent--emit run 'turn-start)
    (chat-agent--dispatch run))))

(defun chat-agent--transform-context (run)
  "Let RUN transform its message context for this step."
  (when-let ((fn (chat-agent-run-state-transform-context-fn run)))
    (let ((messages (funcall fn run (chat-agent-run-state-messages run))))
      (when (listp messages)
        (setf (chat-agent-run-state-messages run) messages)
        (chat-agent--emit run 'context-transformed
                          :message-count (length messages))))))

(defun chat-agent--apply-steering (run)
  "Inject queued steering messages, then the optional steering callback."
  (let ((queued (chat-agent--queue-order
                 run
                 (chat-agent-run-state-steering-queue run)))
        extra)
    (setf (chat-agent-run-state-steering-queue run) nil)
    (when-let ((fn (chat-agent-run-state-steering-fn run)))
      (setq extra (funcall fn run)))
    (let ((messages (append queued extra)))
      (when messages
        (setf (chat-agent-run-state-messages run)
              (append (chat-agent-run-state-messages run) messages))
        (chat-agent--emit run 'steering :messages messages)))))

(defun chat-agent--forced-stop-p (run processed)
  "Return non-nil when RUN explicitly asks to stop after PROCESSED."
  (when-let ((fn (chat-agent-run-state-should-stop-fn run)))
    (funcall fn run processed)))

(defun chat-agent--default-stop-p (processed)
  "Return non-nil when PROCESSED would naturally end the run."
  (and (null (plist-get processed :tool-calls))
       (not (plist-get processed :parse-error))))

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

(defun chat-agent--prepare-next-turn (run processed)
  "Let RUN append messages before a continued turn after PROCESSED."
  (when-let ((fn (chat-agent-run-state-prepare-next-turn-fn run)))
    (let ((messages (funcall fn run processed)))
      (when (and (listp messages) messages)
        (setf (chat-agent-run-state-messages run)
              (append (chat-agent-run-state-messages run) messages))
        (chat-agent--emit run 'prepared-next-turn
                          :messages messages)))))

(defun chat-agent--options-for-turn (run)
  "Return the transport options for the current turn of RUN."
  (let ((base (copy-tree (or (chat-agent-run-state-request-options run) nil)))
        (followup (chat-agent-run-state-followup-request-options run)))
    (when (and (> (chat-agent-run-state-step run) 1) followup)
      (cl-loop for (key value) on followup by #'cddr
               do (setq base (plist-put base key value))))
    (if (chat-agent-budget-final-step-p
         (chat-agent-run-state-max-steps run)
         (chat-agent-run-state-step run))
        ;; The last step has to produce an answer, so it is offered no tools
        ;; to reach for.  Asking the model to stop calling tools works far
        ;; less reliably than not advertising any.
        (setq base (plist-put base :tools nil))
      (when (and (chat-agent-run-state-native-tools run)
                 (null (plist-get base :tools))
                 (fboundp 'chat-tool-caller-provider-tools))
        (let* ((chat-tool-caller-current-session
                (chat-agent-run-state-session run))
               (tools (chat-tool-caller-provider-tools)))
          (when tools
            (setq base (plist-put base :tools tools))))))
    base))

(defun chat-agent--request-messages (run)
  "Return the context for this turn of RUN, with any budget reminder.

The reminder is appended here rather than stored on the run: it describes
the step about to happen, so keeping it would leave a trail of stale
counts in the transcript and repeat them in every later request.  It goes
last because that is where a short instruction is actually noticed."
  (let* ((messages (chat-agent-run-state-messages run))
         (context (chat-context-budget-state
                   messages (chat-agent-run-state-model run)))
         (reminders
          (delq nil
                (list (chat-agent-budget-reminder
                       (chat-agent-run-state-max-steps run)
                       (chat-agent-run-state-step run))
                      (chat-context-budget-reminder context)))))
    ;; Reported once per run rather than per step: it is a configuration
    ;; problem for a person to fix, and repeating it every step would bury
    ;; the run's own output.
    (when (and (= (chat-agent-run-state-step run) 1)
               (chat-context-budget-protected-overflow-p context))
      (message "%s" (chat-context-budget-overflow-warning context)))
    (if reminders
        (append messages
                (mapcar (lambda (reminder)
                          (make-chat-message
                           :id (chat-session-new-message-id "budget")
                           :role :system
                           :content reminder
                           :timestamp (current-time)))
                        reminders))
      messages)))

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
         (chat-agent--request-messages run)
         (lambda (result)
           (unless (chat-agent-run-state-cancelled run)
             (chat-agent--handle-result run result)))
         (lambda (err-message)
           (unless (chat-agent-run-state-cancelled run)
             (chat-agent--emit run 'error :message err-message)
             (chat-agent--finish run 'error err-message)))
         (chat-agent--options-for-turn run))))

;; ------------------------------------------------------------------
;; Stream Accumulation
;; ------------------------------------------------------------------

;; A reply arrives in many small pieces and its consumers want all of it
;; that has arrived, so the obvious accumulator -- `(concat all piece)' --
;; copies everything received so far on every piece.  Replayed against the
;; longest reply in a real log, 340 pieces totalling 321KB, that allocated
;; 52MB: 165 times the text it was carrying, and half of a 100MB collection
;; threshold spent on one reply.  The collection then lands on whoever
;; allocates next, which is how a keystroke comes to pay for a reply that
;; finished a minute earlier.
;;
;; So pieces are held in a list and folded into one string only when the
;; reply is published, and publishing backs off as the reply grows: a short
;; reply publishes on every piece, and past that a piece publishes once the
;; unpublished tail reaches a fraction of what is already out.  Total
;; copying becomes a small multiple of the reply's own length rather than a
;; multiple of the number of pieces.  What it costs is that the tail of a
;; very long reply arrives in fewer, larger steps, which is text arriving
;; faster than anyone reads it.

(defcustom chat-agent-stream-publish-fraction 8
  "How far a reply may run unpublished, as a divisor of its length.

A piece publishes once the unpublished tail reaches the published length
divided by this, so short replies publish on every piece and long ones
back off.  Smaller values publish more often and copy more; a value below
one publishes every piece, at the cost this divisor exists to avoid."
  :type 'integer
  :group 'chat)

(cl-defstruct (chat-agent-stream-text
               (:constructor chat-agent--stream-text-create)
               (:copier nil))
  "Text arriving in pieces.
PUBLISHED is what consumers have been given; PENDING holds the pieces
since, in reverse arrival order, and PENDING-LENGTH their total."
  (published "")
  (pending nil)
  (pending-length 0))

(defun chat-agent--stream-add (text piece)
  "Add PIECE to TEXT.  Return non-nil when TEXT is due to be published."
  (push piece (chat-agent-stream-text-pending text))
  (cl-incf (chat-agent-stream-text-pending-length text) (length piece))
  (or (not (integerp chat-agent-stream-publish-fraction))
      (< chat-agent-stream-publish-fraction 1)
      (>= (* chat-agent-stream-publish-fraction
             (chat-agent-stream-text-pending-length text))
          (length (chat-agent-stream-text-published text)))))

(defun chat-agent--stream-publish (text)
  "Fold what is pending in TEXT in, and return (DELTA . ALL).
DELTA is what this publication adds, ALL everything arrived so far.  A
single pending piece becomes the delta without being copied."
  (let* ((pending (chat-agent-stream-text-pending text))
         (delta (cond ((null pending) "")
                      ((null (cdr pending)) (car pending))
                      (t (apply #'concat (nreverse pending))))))
    (setf (chat-agent-stream-text-pending text) nil
          (chat-agent-stream-text-pending-length text) 0)
    (unless (string-empty-p delta)
      (setf (chat-agent-stream-text-published text)
            (concat (chat-agent-stream-text-published text) delta)))
    (cons delta (chat-agent-stream-text-published text))))

(defun chat-agent--stream-all (text)
  "Return everything TEXT holds, publishing anything still pending."
  (cdr (chat-agent--stream-publish text)))

(defun chat-agent--dispatch-stream (run)
  "Dispatch RUN through the streaming transport."
  (let ((content (chat-agent--stream-text-create))
        (reasoning (chat-agent--stream-text-create)))
    (let* ((request-messages
            (prog1 (chat-agent--request-messages run)
              (chat-log-timing-mark "budget")))
           (proc
           (chat-stream-request
            (chat-agent-run-state-model run)
            request-messages
            (lambda (piece)
              (when (and piece (> (length piece) 0))
                (when (chat-agent--stream-add content piece)
                  (let ((published (chat-agent--stream-publish content)))
                    (chat-agent--emit run 'stream-chunk
                                      :text (car published)
                                      :content (cdr published))))))
            (append (list :stream t
                          :on-reasoning
                          (lambda (piece)
                            (when (and piece (> (length piece) 0))
                              (when (chat-agent--stream-add reasoning piece)
                                (let ((published
                                       (chat-agent--stream-publish reasoning)))
                                  (chat-agent--emit
                                   run 'stream-reasoning
                                   :text (car published)
                                   :reasoning (cdr published)))))))
                    (chat-agent--options-for-turn run)))))
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
            ((string-match-p "abnormally\\|failed\\|killed\\|deleted" event)
             (let ((message (string-trim event)))
               (chat-agent--emit run 'error :message message)
               (chat-agent--finish run 'error message)))
            ((string-match-p "finished\\|exited" event)
             (let ((stream-error (process-get p 'chat-stream-http-error)))
               (if stream-error
                   (progn
                     (chat-agent--emit run 'error :message stream-error)
                     (chat-agent--finish run 'error stream-error))
                 (chat-agent--handle-result
                  run
                  ;; Whatever was still unpublished lands here, so a reply
                  ;; whose tail never reached the publishing threshold is
                  ;; still complete by the time it is recorded.
                  (let ((native (chat-stream-native-result p))
                        (all (chat-agent--stream-all content)))
                    (chat-agent--emit run 'stream-result
                                      :content all
                                      :reasoning (chat-agent--stream-all
                                                  reasoning)
                                      :native native)
                    (append (list :content all
                                  :raw-request nil
                                  :raw-response nil)
                            native)))))))))))))

(defun chat-agent--collect-tool-calls (result content)
  "Return tool calls from native RESULT or JSON-in-text CONTENT."
  (let ((native (plist-get result :tool-calls)))
    (chat-agent-ensure-tool-call-ids
     (cond
      ((and native (listp native) native) native)
      (t (chat-tool-caller-parse content))))))

(defun chat-agent--append-message (run message)
  "Append MESSAGE to RUN transcript."
  (setf (chat-agent-run-state-messages run)
        (append (chat-agent-run-state-messages run) (list message)))
  (chat-agent--emit run 'message-appended :message message))

(defun chat-agent--turn-number (run)
  "Return which turn of the session RUN belongs to.

Counted from the user messages on the session, so it is the session's
numbering rather than a counter of the loop's own that would restart with
every run.  Settled on first use and kept: steering adds a user message
while the run is going, and counting again afterwards would file the rest
of this turn under the next one."
  (or (chat-agent-run-state-turn run)
      (setf (chat-agent-run-state-turn run)
            (let ((session (chat-agent-run-state-session run)))
              (if session
                  (max 1 (seq-count (lambda (message)
                                      (eq (chat-message-role message) :user))
                                    (chat-session-messages session)))
                1)))))

(defun chat-agent--make-assistant-message (run content calls raw-request raw-response)
  "Build the assistant transcript message for RUN.

Stamped where it is made.  Nothing stamped these before -- the stamping
API existed and only tests called it -- so a multi-round run reached disk
as a flat list of messages and the display had to infer turns and steps
from roles, which cannot tell an intermediate step from a final answer."
  (chat-transcript-stamp
   (make-chat-message
    :id (chat-session-new-message-id
         (format "assistant-step-%d" (chat-agent-run-state-step run)))
    :role :assistant
    :content content
    :tool-calls calls
    :raw-request raw-request
    :raw-response raw-response
    :timestamp (current-time))
   :turn (chat-agent--turn-number run)
   :step (chat-agent-run-state-step run)
   ;; Tool calls mean the run continues, so this is a step and not the
   ;; answer.
   :category (if calls 'ai-progress 'ai-final)
   :work (and calls 'message)))

(defun chat-agent--make-tool-message (run call result-text)
  "Build a :tool transcript message for CALL and RESULT-TEXT."
  (let ((id (chat-agent-tool-call-id call))
        (name (plist-get call :name)))
    (chat-transcript-stamp
     (make-chat-message
      :id (chat-session-new-message-id (format "tool-%s" id))
      :role :tool
      :content (chat-tool-caller-truncate-result
                (string-trim-right (or result-text "")))
      :timestamp (current-time)
      :metadata (list :tool-call-id id :name name))
     :turn (chat-agent--turn-number run)
     :step (chat-agent-run-state-step run)
     :category 'ai-progress
     :work 'tool-result)))

(defun chat-agent--resource-conflict-p (left right)
  "Return non-nil when resource accesses LEFT and RIGHT conflict."
  (or (plist-get left :exclusive)
      (plist-get right :exclusive)
      (and (equal (plist-get left :resource)
                  (plist-get right :resource))
           (or (eq (plist-get left :mode) 'write)
               (eq (plist-get right :mode) 'write)))))

(defun chat-agent--accesses-conflict-p (left right)
  "Return non-nil when access lists LEFT and RIGHT conflict."
  (seq-some
   (lambda (a)
     (seq-some (lambda (b) (chat-agent--resource-conflict-p a b))
               right))
   left))

(defun chat-agent--execute-calls-async (run calls observer callback)
  "Schedule CALLS for RUN and invoke CALLBACK with ordered results.
Only asynchronous, non-conflicting calls overlap. Writes and calls that
need approval carry exclusive accesses and therefore remain serialized."
  (let* ((count (length calls))
         (results (make-vector count nil))
         (pending (cl-loop for call in calls
                           for index from 0
                           collect (cons index call)))
         (running (make-hash-table :test 'eql))
         (finished 0)
         (cancelled nil)
         (pumping nil)
         (reported nil)
         (report-fn nil)
         (conflict-fn nil)
         (complete-fn nil)
         (launch-fn nil)
         (pump-fn nil))
    (chat-agent--emit run 'tool-batch-start :count count)
    (setq
     report-fn
     (lambda ()
       (unless reported
         (setq reported t)
         (chat-agent--emit run 'tool-batch-end
                           :count finished
                           :cancelled cancelled)
         (funcall callback
                  (list :results (append results nil)
                        :cancelled cancelled))))
     conflict-fn
     (lambda (accesses)
       (let (conflict)
         (maphash
          (lambda (_index job)
            (when (chat-agent--accesses-conflict-p
                   accesses (plist-get job :accesses))
              (setq conflict t)))
          running)
         conflict))
     complete-fn
     (lambda (index call result)
       (unless (aref results index)
         (aset results index result)
         (remhash index running)
         (cl-incf finished)
         (chat-agent--hook-all
          'chat-plugin-after-tool-call-functions run call result))
       (cond
        ((or cancelled (chat-agent-run-state-cancelled run))
         (setq cancelled t)
         (funcall report-fn))
        ((= finished count)
         (funcall report-fn))
        ((not pumping)
         (funcall pump-fn))))
     launch-fn
     (lambda (entry accesses)
       (let* ((index (car entry))
              (call (cdr entry))
              (display-index (1+ index))
              (blocked (chat-agent--hook-until
                        'chat-plugin-before-tool-call-functions
                        run call)))
         (puthash index (list :call call :accesses accesses :handle nil)
                  running)
         (if (and (listp blocked) (plist-get blocked :block))
             (funcall complete-fn index call
                      (or (plist-get blocked :reason)
                          "Tool execution was blocked"))
           (let ((handle
                  (chat-tool-caller-execute-async
                   call
                   (chat-agent-run-state-session run)
                   (lambda (event)
                     (let ((indexed (copy-tree event)))
                       (setq indexed
                             (plist-put indexed :index display-index))
                       (funcall observer indexed)))
                   (lambda (result)
                     (funcall complete-fn index call result))
                   (lambda (result)
                     (funcall complete-fn index call result)))))
             (when-let ((job (gethash index running)))
               (puthash index (plist-put job :handle handle) running))))))
     pump-fn
     (lambda ()
       (unless (or reported cancelled)
         (setq pumping t)
         (unwind-protect
             (let (launched)
               (while
                   (progn
                     (setq launched nil)
                     (let ((rest pending))
                       (while (and rest (not launched))
                         (let* ((entry (car rest))
                                (accesses
                                 (chat-tool-caller-call-resource-accesses
                                  (cdr entry))))
                           (if (funcall conflict-fn accesses)
                               (setq rest (cdr rest))
                             (setq pending (delq entry pending)
                                   launched t)
                             (funcall launch-fn entry accesses))))
                       launched)))
               (when (and (null pending)
                          (zerop (hash-table-count running))
                          (= finished count))
                 (funcall report-fn)))
           (setq pumping nil)))))
    (chat-agent-add-cancel-function
     run
     (lambda (_run)
       (setq cancelled t
             pending nil)
       (maphash
        (lambda (_index job)
          (chat-tool-caller-cancel-handle (plist-get job :handle)))
        running)
       (funcall report-fn)))
    (if (zerop count)
        (funcall report-fn)
      (funcall pump-fn))))

(defun chat-agent--complete-result (run result processed truncated)
  "Commit PROCESSED transport RESULT for RUN.
TRUNCATED is non-nil when tool calls were refused for length."
  (when (plist-get processed :cancelled)
    (chat-agent--finish run 'cancelled nil)
    (cl-return-from chat-agent--complete-result nil))
  (when truncated
    (let ((calls (plist-get processed :tool-calls)))
      (chat-agent--emit run 'truncated :count (length calls))
      (dolist (call calls)
        (chat-agent--emit run 'tool-event
                          :event (list :type 'tool-error
                                       :tool (plist-get call :name)
                                       :result-summary
                                       chat-agent-truncated-tool-result-text)))))
  (chat-agent--append-message
   run
   ;; Reasoning rides on the step that produced it, so it is on the record
   ;; and foldable without ever becoming a message the next request would
   ;; send back.  The transport had it all along and it was discarded here.
   (chat-transcript-set-reasoning
    (chat-agent--make-assistant-message
     run
     (plist-get processed :content)
     (plist-get processed :tool-calls)
     (plist-get result :raw-request)
     (plist-get result :raw-response))
    (plist-get result :reasoning)))
  (let ((calls (plist-get processed :tool-calls))
        (results (plist-get processed :tool-results)))
    (while (and calls results)
      (chat-agent--append-message
       run
       (chat-agent--make-tool-message run (car calls) (car results)))
      (setq calls (cdr calls)
            results (cdr results))))
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
  (chat-agent--hook-all 'chat-plugin-post-turn-functions run processed)
  (chat-agent--prepare-next-turn run processed)
  (cond
   ((chat-agent-run-state-done run)
    nil)
   ((chat-agent--forced-stop-p run processed)
    (chat-agent--finish run 'completed nil))
   ((chat-agent-run-state-steering-queue run)
    (chat-agent--turn run))
   ((chat-agent--default-stop-p processed)
    (let ((queued (chat-agent--queue-order
                   run
                   (chat-agent-run-state-followup-queue run))))
      (setf (chat-agent-run-state-followup-queue run) nil)
      (if queued
          (progn
            (setf (chat-agent-run-state-messages run)
                  (append (chat-agent-run-state-messages run) queued))
            (chat-agent--emit run 'followup :message (car queued))
            (chat-agent--turn run))
        (chat-agent--finish run 'completed nil))))
   (t
    (chat-agent--queue-followup run processed)
    (chat-agent--turn run))))

(defun chat-agent--handle-result (run result)
  "Process transport RESULT for RUN and continue or finish the loop."
  (setf (chat-agent-run-state-raw-request run) (plist-get result :raw-request)
        (chat-agent-run-state-raw-response run) (plist-get result :raw-response))
  (let* ((content (or (plist-get result :content) ""))
         (calls (chat-agent--collect-tool-calls result content))
         (truncated (and (equal (plist-get result :finish-reason) "length")
                         calls)))
    (cond
     (truncated
      (chat-agent--complete-result
       run result
       (list :content (string-trim-right
                       (chat-tool-caller-extract-content content))
             :tool-calls calls
             :tool-results
             (mapcar (lambda (_call) chat-agent-truncated-tool-result-text)
                     calls)
             :tool-events nil
             :parse-error nil
             :truncated-tool-calls t)
       t))
     (calls
      (let (tool-events)
        (chat-agent--execute-calls-async
         run calls
         (lambda (event)
           (push event tool-events)
           (chat-agent--emit run 'tool-event :event event))
         (lambda (execution)
           (unless (chat-agent-run-state-done run)
             (if (plist-get execution :cancelled)
                 (chat-agent--finish run 'cancelled nil)
               (chat-agent--complete-result
                run result
                (list :content
                      (string-trim-right
                       (chat-tool-caller-extract-content content))
                      :tool-calls calls
                      :tool-results (plist-get execution :results)
                      :tool-events (nreverse tool-events)
                      :parse-error nil)
                nil)))))))
     (t
      (chat-agent--complete-result
       run result
       (chat-tool-caller-process-response-data
        content
        (chat-agent-run-state-session run)
        (lambda (event)
          (chat-agent--emit run 'tool-event :event event)))
       nil)))))

(defun chat-agent--queue-followup (run processed)
  "Queue parse-error or caller follow-up text after PROCESSED.
Tool results already live on the transcript as :tool messages."
  (let ((text
         (cond
          ((chat-agent-run-state-followup-fn run)
           (funcall (chat-agent-run-state-followup-fn run) processed))
          ((and (null (plist-get processed :tool-calls))
                (plist-get processed :parse-error))
           chat-tool-caller-parse-error-followup-text)
          (t nil))))
    (when (and (stringp text) (not (string-blank-p text)))
      (let ((message (make-chat-message
                      :id (chat-session-new-message-id
                           (format "agent-step-%d"
                                   (chat-agent-run-state-step run)))
                      :role :system
                      :content text
                      :timestamp (current-time))))
        (chat-agent--append-message run message)
        (chat-agent--emit run 'followup :message message)))))

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
  "Build the default follow-up text for PROCESSED.
Kept for callers and tests.  The loop itself prefers :tool messages."
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
     "If another tool is needed, call tools through the provider tool API.\n"
     "Otherwise answer normally.")))

(provide 'chat-agent-loop)
;;; chat-agent-loop.el ends here
