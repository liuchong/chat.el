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
(require 'chat-agent-progress)
(require 'chat-log)
(require 'chat-session)
(require 'chat-transcript)
(require 'chat-context-budget)
(require 'chat-work-context)
(require 'chat-work-plan)
(require 'chat-goal)
(require 'chat-plan-mode)
(require 'chat-event)
(require 'chat-checkpoint)
(require 'chat-tool-caller)
(require 'chat-llm)
(require 'chat-model-runtime)

(defvar chat-plugin-before-tool-call-functions nil)
(defvar chat-plugin-after-tool-call-functions nil)
(defvar chat-plugin-pre-step-functions nil)
(defvar chat-plugin-post-turn-functions nil)

(defcustom chat-agent-work-plan-finalization-max-attempts 2
  "Maximum prompted attempts to close an active work plan before stopping."
  :type 'integer
  :group 'chat)

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
    (chat-agent--apply-pending-model-switch run)
    (setf (chat-agent-run-state-step run)
          (1+ (chat-agent-run-state-step run)))
    (chat-agent--apply-steering run)
    (chat-agent--hook-all 'chat-plugin-pre-step-functions run)
    (chat-log-timing-mark "steer")
    (chat-agent--transform-context run)
    (chat-log-timing-mark "transform")
    (setf (chat-agent-run-state-turn-open run) t)
    (chat-agent--emit run 'turn-start)
    (chat-agent--dispatch run))))

(defun chat-agent--apply-pending-model-switch (run)
  "Atomically apply RUN's pending model switch before a request starts."
  (when-let ((switch (chat-agent-run-state-pending-model-switch run)))
    (let ((provider (plist-get switch :provider))
          (model (plist-get switch :model)))
      (setf (chat-agent-run-state-provider run) provider
            (chat-agent-run-state-model run) model
            (chat-agent-run-state-request-options run)
            (plist-put (copy-tree
                        (or (plist-get switch :request-options)
                            (chat-agent-run-state-request-options run)))
                       :model model)
            (chat-agent-run-state-pending-model-switch run) nil)
      (chat-agent--emit run 'model-switched
                        :provider provider
                        :model model
                        :operation-id (plist-get switch :operation-id)
                        :source (plist-get switch :source))
      switch)))

(defun chat-agent--transform-context (run)
  "Let RUN transform its message context for this step."
  (when-let ((fn (chat-agent-run-state-transform-context-fn run)))
    (let ((messages (funcall fn run (chat-agent-run-state-messages run))))
      (when (listp messages)
        (setf (chat-agent-run-state-messages run) messages)
        (chat-agent--emit run 'context-transformed
                          :message-count (length messages))))))

(defun chat-agent--steering-marker (index total timestamp)
  "Return the line that introduces one injected message.

INDEX of TOTAL, sent at TIMESTAMP.  Three messages arriving mid-run used
to reach the model as three adjacent user turns with nothing to tell them
apart: the struct's timestamp and id are not on the wire, only role and
content are.  So the model could not tell a correction from an addition,
nor which of the three was the latest.

English regardless of interface language.  This is a protocol marker read
by the model, not a string read by the user; localising it would make the
same situation look different to different models for no gain."
  (format "[%sarrived while you were working · %s]"
          (if (> total 1) (format "input %d of %d · " index total) "")
          (format-time-string "%H:%M:%S" timestamp)))

(defun chat-agent--annotate-steering (messages)
  "Return MESSAGES with each one introduced by its position in the batch.

Copies rather than edits: the same structs are already in the session and
on screen, where the marker would be noise.  It belongs on the wire only."
  (let ((total (length messages))
        (index 0))
    (mapcar
     (lambda (message)
       (setq index (1+ index))
       (if (not (chat-message-p message))
           message
         (let ((copy (copy-chat-message message)))
           (setf (chat-message-content copy)
                 (concat (chat-agent--steering-marker
                          index total (chat-message-timestamp message))
                         "\n"
                         (or (chat-message-content message) "")))
           copy)))
     messages)))

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
              (append (chat-agent-run-state-messages run)
                      (chat-agent--annotate-steering messages)))
        (chat-agent--emit run 'steering
                          :messages messages
                          :max-steps (chat-agent-run-state-max-steps run))))))

(defun chat-agent--forced-stop-p (run processed)
  "Return non-nil when RUN explicitly asks to stop after PROCESSED."
  (when-let ((fn (chat-agent-run-state-should-stop-fn run)))
    (funcall fn run processed)))

(defun chat-agent--default-stop-p (processed)
  "Return non-nil when PROCESSED would naturally end the run."
  (and (null (plist-get processed :tool-calls))
       (not (plist-get processed :parse-error))))

(defun chat-agent--applicable-open-work-plan (run)
  "Return RUN's active or blocked task plan, if one is still open."
  (when-let* ((session (chat-agent-run-state-session run))
              (plan (chat-work-plan-current session t))
              ((memq (chat-work-plan-status plan) '(active blocked)))
              ((or (null (chat-agent-run-state-task-id run))
                   (null (chat-work-plan-task-id plan))
                   (equal (chat-agent-run-state-task-id run)
                          (chat-work-plan-task-id plan)))))
    plan))

(defun chat-agent--work-plan-finalization-turn-available-p (run)
  "Return non-nil when RUN can still offer tools on another turn."
  (let ((limit (chat-agent-run-state-max-steps run))
        (next-step (1+ (chat-agent-run-state-step run))))
    (and (< (chat-agent-run-state-work-plan-finalization-attempts run)
            chat-agent-work-plan-finalization-max-attempts)
         (or (eq limit 'unlimited)
             ;; The final step deliberately advertises no tools.  A plan
             ;; closure retry therefore needs a turn strictly before it.
             (< next-step limit)))))

(defun chat-agent--work-plan-finalization-message (plan)
  "Return the request-only closure instruction for PLAN."
  (let* ((slice (chat-work-plan-active-slice plan))
         (item (plist-get slice :current-item)))
    (string-join
     (delq
      nil
      (list
       "[work plan finalization required]"
       (format "Plan %s revision %d is still %s."
               (chat-work-plan-id plan)
               (chat-work-plan-revision plan)
               (chat-work-plan-status plan))
       (and item
            (format "Current item %s (%s): %s"
                    (chat-work-plan-item-id item)
                    (chat-work-plan-item-status item)
                    (chat-work-plan-item-title item)))
       (and item (chat-work-plan-item-acceptance item)
            (format "Acceptance: %s"
                    (chat-work-plan-item-acceptance item)))
       "Do not create another plan and do not claim completion while this plan is open."
       "If the acceptance condition is proven, call `programming_plan_transition` with the exact current revision and known Evidence IDs."
       "If the work cannot be completed now, transition the current item to blocked with a concrete reason, or cancel the plan when the work is intentionally abandoned."))
     "\n")))

(defun chat-agent--finish-or-finalize-work-plan (run)
  "Finish RUN, or schedule a bounded attempt to settle its open work plan."
  (if-let ((plan (chat-agent--applicable-open-work-plan run)))
      (cond
       ((eq (chat-work-plan-status plan) 'blocked)
        (chat-agent--emit run 'work-plan-finalization
                          :action 'stopped
                          :plan-id (chat-work-plan-id plan)
                          :revision (chat-work-plan-revision plan)
                          :status 'blocked)
        (chat-agent--finish run 'stopped 'work-plan-blocked))
       ((not (chat-agent--work-plan-finalization-turn-available-p run))
        (chat-agent--emit run 'work-plan-finalization
                          :action 'stopped
                          :plan-id (chat-work-plan-id plan)
                          :revision (chat-work-plan-revision plan)
                          :status (chat-work-plan-status plan))
        (chat-agent--finish run 'stopped 'active-plan-unclosed))
       (t
        (cl-incf (chat-agent-run-state-work-plan-finalization-attempts run))
        (let ((message
               (make-chat-message
                :id (chat-session-new-message-id "plan-finalization")
                :role :system
                :content (chat-agent--work-plan-finalization-message plan)
                :timestamp (current-time)
                :metadata '(:ephemeral t :work-plan-finalization t))))
          (setf (chat-agent-run-state-messages run)
                (append (chat-agent-run-state-messages run) (list message)))
          (chat-agent--emit run 'work-plan-finalization
                            :action 'retry
                            :attempt
                            (chat-agent-run-state-work-plan-finalization-attempts
                             run)
                            :plan-id (chat-work-plan-id plan)
                            :revision (chat-work-plan-revision plan)
                            :status (chat-work-plan-status plan))
          (chat-agent--emit run 'followup :message message)
          (chat-agent--turn run))))
    (chat-agent--finish run 'completed nil)))

(defun chat-agent--finish (run status reason)
  "Finish RUN once with STATUS and REASON and emit the final event."
  (unless (chat-agent-run-state-done run)
    (chat-agent--close-turn run status reason)
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

(defun chat-agent--close-turn (run status &optional reason)
  "Close RUN's current turn once with STATUS and REASON."
  (when (chat-agent-run-state-turn-open run)
    (setf (chat-agent-run-state-turn-open run) nil)
    (if (eq status 'error)
        (chat-agent--emit run 'turn-failed
                          :status status
                          :reason reason)
      (chat-agent--emit run 'turn-ended
                        :status status
                        :reason reason))))

(defun chat-agent--event-session-id (run)
  "Return RUN's session id, or nil."
  (when-let* ((session (chat-agent-run-state-session run)))
    (chat-session-id session)))

(defun chat-agent--synchronize-execution-session (run)
  "Refresh RUN's transient execution Session from its canonical Session.

The canonical Session is the sole owner of durable state.  Stateful tools
receive it explicitly, while the execution Session is only a transient copy
for provider tool menus and approval policy.  Refreshing in the other
direction can overwrite a Plan or Goal that the tool just committed."
  (let ((session (chat-agent-run-state-session run))
        (execution (chat-agent-run-state-execution-session run)))
    (when (and session execution (not (eq session execution)))
      (setf (chat-session-metadata execution)
            (copy-tree (chat-session-metadata session))
            (chat-session-updated-at execution)
            (chat-session-updated-at session)))))

(defun chat-agent--tool-event-payload (call &optional result)
  "Return bounded lifecycle facts for CALL and optional RESULT."
  (let ((arguments (plist-get call :arguments)))
    (delq nil
          (list
           (cons 'tool (format "%s" (plist-get call :name)))
           (when-let* ((id (plist-get call :id)))
             (cons 'tool_call_id id))
           (cons 'argument_count (if (listp arguments)
                                     (length arguments)
                                   (if arguments 1 0)))
           (when (stringp result)
             (cons 'result_chars (length result)))))))

(defun chat-agent--publish-tool-event (run type call &optional result)
  "Publish lifecycle TYPE for CALL in RUN with optional RESULT."
  (let ((event
         (chat-event-create
          :type type
          :session-id (chat-agent--event-session-id run)
          :turn-id (chat-agent-run-state-turn run)
          :task-id (plist-get call :id)
          :source 'tool
          :payload (chat-agent--tool-event-payload call result)
          :subject call
          :context
          (delq nil
                (list
                 (cons 'step (chat-agent-run-state-step run))
                 (when-let* ((task-id (chat-agent-run-state-task-id run)))
                   (cons 'agent_task_id task-id)))))))
    (cons event (chat-event-publish event))))

(defun chat-agent--result-with-evidence-id (result evidence-id)
  "Prefix successful tool RESULT with its scoped EVIDENCE-ID."
  (let* ((source (or result ""))
         (format-name
          (and (stringp source)
               (get-text-property 0 'chat-tool-result-format source)))
         (text (format "Evidence ID: %s\n%s" evidence-id source)))
    (if format-name
        (propertize text 'chat-tool-result-format format-name)
      text)))

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
                 (not
                  (null
                   (chat-model-capabilities-tools
                    (chat-model-capabilities-resolve
                     (chat-agent-run-state-provider run)
                     (chat-agent-run-state-model run)))))
                 (fboundp 'chat-tool-caller-provider-tools))
        (let* ((chat-tool-caller-current-session
                (chat-agent-run-execution-session run))
               (tools (chat-tool-caller-provider-tools)))
          (when tools
            (setq base (plist-put base :tools tools))))))
    ;; Provider profiles and follow-up options may change budgets, never model
    ;; identity.  Pin last so no secondary option source can override the run.
    (plist-put base :model (chat-agent-run-state-model run))))

(defun chat-agent--context-selection (run)
  "Return RUN's request-time scoped context bundle."
  (let* ((session (chat-agent-run-state-session run))
         (plan-session session)
         (session-id (and session (chat-session-id session)))
         (task-id (chat-agent-run-state-task-id run))
         (project-root
          (or (chat-agent-run-state-project-root run)
              (and session (chat-session-root-directory session))
              (and session (chat-session-working-directory session))))
         (target-path
          (or (chat-agent-run-state-context-target-path run)
              (and session (chat-session-working-directory session))
              project-root))
         (turn-id (chat-agent--turn-number run))
         (context (list :session-id session-id :turn-id turn-id
                        :task-id task-id :project-root project-root
                        :target-path target-path))
         (notes (and session-id
                     (chat-work-note-fragments session-id context)))
         (goal-fragment
          (and session
               (chat-goal-context-fragment
                session
                (chat-agent-run-state-goal-projection-revision run))))
         (plan-mode-fragment
          (and session (chat-plan-mode-context-fragment session)))
         (plan-fragment
          (and plan-session
               (chat-work-plan-context-fragment
                plan-session task-id
                (chat-agent-run-state-work-plan-projection-revision run))))
         (window (chat-context-window-for-model
                  (chat-agent-run-state-provider run)))
         (max-chars
          (* 4 (+ (chat-context-allocation-tokens 'resident-rules window)
                  (chat-context-allocation-tokens 'project-notes window))))
         (bundle
          (chat-context-bundle-build
           (append (chat-agent-run-state-context-fragments run)
                   (and goal-fragment (list goal-fragment))
                   (and plan-mode-fragment (list plan-mode-fragment)) notes
                   (and plan-fragment (list plan-fragment)))
           :session-id session-id :turn-id turn-id :task-id task-id
           :project-root project-root :target-path target-path
           :max-chars (min chat-work-context-max-projection-chars max-chars))))
    (setf (chat-agent-run-state-last-context-bundle run) bundle)
    (when goal-fragment
      (setf (chat-agent-run-state-goal-projection-revision run)
            (cdr (assq 'revision
                       (chat-context-fragment-metadata goal-fragment)))))
    (when plan-fragment
      (setf (chat-agent-run-state-work-plan-projection-revision run)
            (cdr (assq 'revision
                       (chat-context-fragment-metadata plan-fragment)))))
    (chat-agent--emit
     run 'context-bundle :digest (chat-context-bundle-digest bundle)
     :selected-count (length (chat-context-bundle-fragments bundle))
     :omitted-count (length (chat-context-bundle-omitted bundle)))
    bundle))

(defun chat-agent--context-message (fragment)
  "Serialize one typed context FRAGMENT for a provider request."
  (make-chat-message
   :id (concat "request-context:" (chat-context-fragment-id fragment))
   :role :system
   :content (chat-context-bundle-render
             (chat-context-bundle-create :fragments (list fragment)))
   :timestamp (current-time)
   :metadata
   (list :ephemeral t :context-fragment-id (chat-context-fragment-id fragment)
         :context-kind (chat-context-fragment-kind fragment)
         :context-authority (chat-context-fragment-authority fragment)
         :context-scope (chat-context-fragment-scope fragment)
         :context-source-id (chat-context-fragment-source-id fragment)
         :context-digest (chat-context-fragment-digest fragment))))

(defun chat-agent--insert-context-messages (messages bundle)
  "Insert BUNDLE projections after the leading system MESSAGES."
  (pcase-let ((`(,systems ,rest)
               (chat-context--partition-system-messages messages)))
    (append systems
            (mapcar #'chat-agent--context-message
                    (chat-context-bundle-fragments bundle))
            rest)))

(defun chat-agent--refresh-tool-system-messages (run messages)
  "Rebuild request-only tool prompts in MESSAGES for the current RUN turn.

Native tool schemas are selected from the execution Session on every turn.
The textual contract must use that same menu; otherwise a plan created on an
earlier turn can leave the model reading obsolete instructions to create it
again even though the native create tool has already disappeared."
  (mapcar
   (lambda (message)
     (let ((base (and (chat-message-p message)
                      (plist-get (chat-message-metadata message)
                                 :tool-system-prompt-base))))
       (if (not (stringp base))
           message
         (let ((copy (copy-chat-message message)))
           (setf (chat-message-content copy)
                 (chat-tool-caller-build-system-prompt
                  base
                  (chat-agent-run-state-max-steps run)
                  (chat-agent-run-execution-session run)))
           copy))))
   messages))

(defun chat-agent--request-messages (run)
  "Return request context for RUN with scoped fragments and reminders.

The reminder is appended here rather than stored on the run: it describes
the step about to happen, so keeping it would leave a trail of stale
counts in the transcript and repeat them in every later request.  It goes
last because that is where a short instruction is actually noticed.
Context fragments are also request-only: durable notes and rules remain typed
state and are rebuilt after compaction instead of entering the transcript."
  (let* ((bundle (chat-agent--context-selection run))
         (base-messages
          (chat-agent--refresh-tool-system-messages
           run (chat-agent-run-state-messages run)))
         (messages (chat-agent--insert-context-messages
                    base-messages bundle))
         (context (chat-context-budget-state
                   messages (chat-agent-run-state-provider run)))
         (reminders
          (delq nil
                (list (chat-agent-budget-reminder
                       (chat-agent-run-state-max-steps run)
                       (chat-agent-run-state-step run))
                      (chat-context-budget-reminder context)
                      (chat-agent-progress-state-reminder
                       (chat-agent-run-state-progress-state run))))))
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
  (chat-agent--dispatch-model run nil))

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
  (chat-agent--dispatch-model run t))

(defun chat-agent--publish-model-delta (run type text-state piece)
  "Publish PIECE for RUN as TYPE using TEXT-STATE batching."
  (when (and (stringp piece) (not (string-empty-p piece))
             (chat-agent--stream-add text-state piece))
    (let ((published (chat-agent--stream-publish text-state)))
      (if (eq type 'stream-reasoning)
          (chat-agent--emit run type
                            :text (car published)
                            :reasoning (cdr published))
        (chat-agent--emit run type
                          :text (car published)
                          :content (cdr published))))))

(defun chat-agent--transient-model-error-p (message &optional class)
  "Return non-nil when MESSAGE (or its transport CLASS) is retryable.

CLASS is the transport's own classification when it has one
\(chat-stream-net); MESSAGE matching stays for the url.el transport and
for the historical curl exit codes in saved logs."
  (or (memq class '(dns connect tls mid-stream-close http-5xx))
      (and (stringp message)
           (string-match-p
            (concat
             "\\(?:exited abnormally with code "
             "\\(?:6\\|7\\|16\\|18\\|28\\|35\\|52\\|55\\|56\\|92\\)\\b"
             "\\|connection reset\\|connection refused\\|temporary failure"
             "\\|timed? out\\|closed mid-stream\\|stalled"
             "\\|connection broken\\|cannot resolve\\|cannot connect"
             "\\|tls negotiation\\)")
            (downcase message)))))

(defun chat-agent--transport-retry-delay (attempt)
  "Return the nonnegative retry delay for zero-based ATTEMPT."
  (let* ((delays (seq-filter
                  (lambda (delay) (and (numberp delay) (>= delay 0)))
                  chat-agent-model-transport-retry-delays))
         (delay (or (nth attempt delays) (car (last delays)) 0)))
    (float delay)))

(defun chat-agent--dispatch-model (run stream &optional retry-attempt)
  "Dispatch RUN through the unified model runtime using STREAM when non-nil.
RETRY-ATTEMPT counts transport retries for this one model turn."
  (let ((content (chat-agent--stream-text-create))
        (reasoning (chat-agent--stream-text-create))
        (received-payload nil)
        (attempt (or retry-attempt 0))
        (request-messages
         (prog1 (chat-agent--request-messages run)
           (chat-log-timing-mark "budget"))))
    (setf (chat-agent-run-state-handle run) nil)
    (let ((request-handle
           (chat-model-request-events
            (chat-agent-run-state-provider run)
            request-messages
            (lambda (event)
        (unless (chat-agent-run-state-cancelled run)
          (let ((payload (chat-model-event-payload event)))
            (pcase (chat-model-event-type event)
              ('started
               (chat-agent--emit
                run 'model-request-started
                :provider (chat-model-event-provider event)
                :model (chat-model-event-model event)
                :request-id (chat-model-event-request-id event)))
              ('text-delta
               (setq received-payload t)
               (when stream
                 (chat-agent--publish-model-delta
                  run 'stream-chunk content (plist-get payload :delta))))
              ('reasoning-delta
               (setq received-payload t)
               (when stream
                 (chat-agent--publish-model-delta
                  run 'stream-reasoning reasoning
                  (plist-get payload :delta))))
              ('tool-call-delta
               (setq received-payload t)
               (chat-agent--emit run 'model-tool-call-delta
                                 :delta payload))
              ('usage
               (setq received-payload t)
               (chat-agent--emit run 'model-usage :usage payload))
              ('completed
               (let ((result (plist-get payload :result)))
                 (when stream
                   ;; Flush any tail that did not reach the adaptive publish
                   ;; threshold before recording the complete provider result.
                   (chat-agent--stream-all content)
                   (chat-agent--stream-all reasoning)
                   (chat-agent--emit
                    run 'stream-result
                    :content (plist-get result :content)
                    :reasoning (plist-get result :reasoning)
                    :native result))
                 (chat-agent--handle-result run result)))
              ('error
               (let ((message (plist-get payload :message))
                     (class (plist-get payload :class)))
                 (cond
                  ((and (not received-payload)
                        (< attempt chat-agent-model-transport-retries)
                        (chat-agent--transient-model-error-p message class))
                   (let* ((retry (1+ attempt))
                          (delay (chat-agent--transport-retry-delay attempt)))
                     (chat-agent--emit
                      run 'model-retry :attempt retry
                      :delay-seconds delay
                      :message (truncate-string-to-width
                                message 256 nil nil t))
                     (setf
                      (chat-agent-run-state-handle run)
                      (run-at-time
                       delay nil
                       (lambda ()
                         (unless (or (chat-agent-run-state-cancelled run)
                                     (chat-agent-run-state-done run))
                           (chat-agent--dispatch-model
                            run stream retry)))))))
                  ((and received-payload
                        (< (chat-agent-run-state-stream-resume-attempts run)
                           chat-agent-model-stream-resume-retries)
                        (chat-agent--transient-model-error-p message class))
                   ;; The turn already streamed partial content, so the
                   ;; no-payload retry above no longer applies.  Re-send
                   ;; the turn from scratch instead: nothing was recorded
                   ;; and tools only run after a turn completes, so the
                   ;; only cost of the second attempt is its tokens.
                   (setf (chat-agent-run-state-stream-resume-attempts run)
                         (1+ (chat-agent-run-state-stream-resume-attempts
                              run)))
                   (let ((delay (chat-agent--transport-retry-delay
                                 (chat-agent-run-state-stream-resume-attempts
                                  run))))
                     (chat-agent--emit
                      run 'model-retry
                      :attempt (chat-agent-run-state-stream-resume-attempts
                                run)
                      :resume t
                      :delay-seconds delay
                      :message (truncate-string-to-width
                                message 256 nil nil t))
                     (setf
                      (chat-agent-run-state-handle run)
                      (run-at-time
                       delay nil
                       (lambda ()
                         (unless (or (chat-agent-run-state-cancelled run)
                                     (chat-agent-run-state-done run))
                           (chat-agent--dispatch-model
                            run stream attempt)))))))
                  (t
                   (chat-agent--emit run 'error :message message)
                   (chat-agent--finish run 'error message)))))))))
            (plist-put (chat-agent--options-for-turn run) :stream stream))))
      ;; A synchronous error callback may already have installed a retry timer.
      (when (and (null (chat-agent-run-state-handle run))
                 (not (chat-agent-run-state-done run)))
        (setf (chat-agent-run-state-handle run) request-handle)))))

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

(defun chat-agent--make-assistant-message
    (run content calls raw-request raw-response &optional continues)
  "Build the assistant transcript message for RUN.

CONTINUES marks a tool-free reply that cannot settle the run yet.

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
   ;; Tool calls or an open completion barrier mean the run continues, so
   ;; this is a step and not the answer.
   :category (if (or calls continues) 'ai-progress 'ai-final)
   :work (and (or calls continues) 'message)))

(defun chat-agent--make-tool-message (run call result-text)
  "Build a :tool transcript message for CALL and RESULT-TEXT."
  (let* ((id (chat-agent-tool-call-id call))
         (name (plist-get call :name))
         (source (string-trim-right (or result-text "")))
         (format-name
          (and (stringp result-text)
               (<= (length source) chat-tool-caller-result-max-chars)
               (get-text-property
                0 'chat-tool-result-format result-text))))
    (chat-transcript-stamp
     (make-chat-message
      :id (chat-session-new-message-id (format "tool-%s" id))
      :role :tool
      :content (chat-tool-caller-truncate-result source)
      :timestamp (current-time)
      :metadata (append (list :tool-call-id id :name name)
                        (when format-name
                          (list :content-format format-name))))
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
         (failures (make-vector count nil))
         (progresses (make-vector count 'untracked))
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
                        :failures (append failures nil)
                        :progresses (append progresses nil)
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
     (lambda (index call result &optional failed)
       (unless (or failed
                   (null (chat-agent-run-state-session run)))
         (condition-case err
             (aset progresses index
                   (chat-checkpoint-tool-change-status
                    (chat-agent-run-state-session run)
                    (chat-agent-run-state-turn run)
                    call))
           (error
            (setq failed t
                  result
                  (format "Tool progress observation failed: %s"
                          (error-message-string err))))))
       (unless (or failed
                   (null (chat-agent-run-state-session run)))
         (condition-case err
             (chat-checkpoint-complete-tool
              (chat-agent-run-state-session run)
              (chat-agent-run-state-turn run)
              call)
           (error
            (setq failed t
                  result
                  (format "Tool changed files but checkpoint ownership failed: %s"
                          (error-message-string err))))))
       (unless (aref results index)
         (aset results index result)
         (aset failures index (and failed t))
         (remhash index running)
         (cl-incf finished)
         (unless failed
           (chat-agent--synchronize-execution-session run))
         (when (and (not failed)
                    (chat-agent-run-state-session run)
                    (fboundp 'chat-code-session-project-root)
                    (fboundp 'chat-repo-map-update-tool-call))
           (when-let* ((root
                        (chat-code-session-project-root
                         (chat-agent-run-state-session run))))
             (chat-repo-map-update-tool-call root call)))
         (let* ((lifecycle
                 (chat-agent--publish-tool-event run 'post-tool call result))
                (evidence-id
                 (and (not failed)
                      (chat-agent-run-state-session run)
                      (chat-agent-run-state-task-id run)
                      (chat-event-id (car lifecycle)))))
           (when evidence-id
             (aset results index
                   (chat-agent--result-with-evidence-id result evidence-id))))
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
     (lambda (entry)
       (let* ((index (car entry))
              (call (cdr entry))
              (display-index (1+ index))
              (lifecycle (chat-agent--publish-tool-event
                          run 'pre-tool call))
              (lifecycle-event (car lifecycle))
              (lifecycle-outcome (cdr lifecycle))
              (call (chat-event-subject lifecycle-event))
              (accesses (chat-tool-caller-call-resource-accesses call))
              (blocked (chat-agent--hook-until
                        'chat-plugin-before-tool-call-functions
                        run call))
              plan-mode-refusal)
         (puthash index (list :call call :accesses accesses :handle nil)
                  running)
         (cond
          ((not (chat-event-allowed-p lifecycle-outcome))
           (funcall complete-fn index call
                    (or (plist-get lifecycle-outcome :reason)
                        "Tool execution was blocked by runtime policy")
                    t))
          ((and (listp blocked) (plist-get blocked :block))
           (funcall complete-fn index call
                    (or (plist-get blocked :reason)
                        "Tool execution was blocked")
                    t))
          ((setq plan-mode-refusal
                 (chat-plan-mode-check-call
                  (chat-agent-run-state-session run) call))
           (funcall complete-fn index call plan-mode-refusal t))
          (t
           (condition-case err
               (progn
                 (when (chat-agent-run-state-session run)
                   (chat-checkpoint-before-tool
                    (chat-agent-run-state-session run)
                    (chat-agent-run-state-turn run)
                    call))
                 (let ((handle
                        (chat-tool-caller-execute-async
                         call
                         (chat-agent-run-execution-session run)
                         (lambda (event)
                           (let ((indexed (copy-tree event)))
                             (setq indexed
                                   (plist-put indexed :index display-index))
                             (funcall observer indexed)))
                         (lambda (result)
                           (funcall
                            complete-fn index call result
                            (and (stringp result)
                                 (string-match-p
                                  "\\`\\(?:Error\\|Denied\\):" result))))
                         (lambda (result)
                           (funcall complete-fn index call result t))
                         (list
                          :session-id
                          (and (chat-agent-run-state-session run)
                               (chat-session-id
                                (chat-agent-run-state-session run)))
                          :turn-id (chat-agent-run-state-turn run)
                          :task-id (chat-agent-run-state-task-id run)
                          :run-id (chat-agent-run-state-run-id run)
                          :read-set (chat-agent-run-state-read-set run))
                         (chat-agent-run-state-session run))))
                   (when-let* ((job (gethash index running)))
                     (puthash index (plist-put job :handle handle) running))))
             (error
              (funcall complete-fn index call
                       (format "Tool checkpoint failed: %s"
                               (error-message-string err))
                       t)))))))
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
                             (funcall launch-fn entry))))
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

(defun chat-agent--progress-tool-kind (call failed change-status)
  "Return semantic progress kind for CALL, FAILED and CHANGE-STATUS."
  (let ((name (or (plist-get call :name) "")))
    (cond
     (failed 'error)
     ((string-match-p
       "\\`\\(?:programming_plan_\\|goal_\\|work_note_\\|todo_\\)"
       name)
      'neutral)
     ((string-prefix-p "programming_verification_" name)
      'progress)
     ((eq change-status 'changed)
      'progress)
     ((eq change-status 'unchanged)
      'inspection)
     ((seq-some (lambda (access)
                  (eq (plist-get access :mode) 'write))
                (chat-tool-caller-call-resource-accesses call))
      'progress)
     (t 'inspection))))

(defun chat-agent--progress-inspection-key (call)
  "Return a bounded semantic inspection key for CALL."
  (let ((resources
         (sort
          (delete-dups
           (mapcar
            (lambda (access) (format "%s" (plist-get access :resource)))
            (chat-tool-caller-call-resource-accesses call)))
          #'string<)))
    (secure-hash
     'sha256
     (concat (or (plist-get call :name) "unknown") "\0"
             (string-join resources "\0")))))

(defun chat-agent--tool-result-failed-p (result)
  "Return non-nil when RESULT is an explicit failed tool observation."
  (or (and (stringp result)
           (string-match-p "\\`\\(?:Error\\|Denied\\)\\b" result))
      (and (listp result)
           (memq (plist-get result :status) '(error failed denied)))))

(defun chat-agent--observe-progress (run calls results failures progresses)
  "Update RUN progress from ordered tool observations."
  (let ((state (chat-agent-run-state-progress-state run)))
    (while calls
      (let* ((call (car calls))
             (failed (or (car failures)
                         (chat-agent--tool-result-failed-p (car results))))
             (kind (chat-agent--progress-tool-kind
                    call failed (car progresses)))
             (event
              (chat-agent-progress-observe
               state kind
               (and (eq kind 'inspection)
                    (chat-agent--progress-inspection-key call)))))
        (when event
          (chat-agent--emit
           run (plist-get event :event)
           :inspection-count (plist-get event :inspection-count)
           :repeat-count (plist-get event :repeat-count)
           :warning-count (plist-get event :warning-count)))
        (setq calls (cdr calls)
              results (cdr results)
              failures (cdr failures)
              progresses (cdr progresses))))
    state))

(cl-defun chat-agent--complete-result (run result processed truncated)
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
  (when (and (null (plist-get processed :tool-calls))
             (fboundp 'chat-code-verify-latest-for-session)
             (fboundp 'chat-code-verify-summary))
    (when-let* ((session-id (chat-agent--event-session-id run))
                (verification
                 (chat-code-verify-latest-for-session
                  session-id (chat-agent--turn-number run))))
      (setq processed
            (plist-put
             processed :content
             (concat
              (string-trim-right (or (plist-get processed :content) ""))
              "\n\n"
              (chat-code-verify-summary verification))))))
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
     (plist-get result :raw-response)
     (and (null (plist-get processed :tool-calls))
          (let ((plan (chat-agent--applicable-open-work-plan run)))
            (and plan (eq (chat-work-plan-status plan) 'active)))))
    (plist-get result :reasoning)))
  (let ((calls (plist-get processed :tool-calls))
        (results (plist-get processed :tool-results))
        (failures (or (plist-get processed :tool-failures)
                      (make-list
                       (length (plist-get processed :tool-calls)) nil)))
        (progresses (or (plist-get processed :tool-progresses)
                        (make-list
                         (length (plist-get processed :tool-calls))
                         'untracked))))
    (chat-agent--observe-progress run calls results failures progresses)
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
  (chat-agent--close-turn run 'completed)
  (chat-agent--hook-all 'chat-plugin-post-turn-functions run processed)
  (chat-agent--prepare-next-turn run processed)
  (cond
   ((chat-agent-run-state-done run)
    nil)
   ((chat-agent-progress-state-stop-reason
     (chat-agent-run-state-progress-state run))
    (chat-agent--finish
     run 'error
     (chat-agent-progress-state-stop-reason
      (chat-agent-run-state-progress-state run))))
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
        (if (chat-agent--queue-followup run processed)
            (chat-agent--turn run)
          (chat-agent--finish-or-finalize-work-plan run)))))
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
             :tool-failures (make-list (length calls) t)
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
                      :tool-failures (plist-get execution :failures)
                      :tool-progresses (plist-get execution :progresses)
                      :tool-events (nreverse tool-events)
                      :parse-error nil)
                nil)))))))
     (t
      (chat-agent--complete-result
       run result
       (chat-tool-caller-process-response-data
        content
        (chat-agent-run-execution-session run)
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
        (chat-agent--emit run 'followup :message message)
        message))))

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
