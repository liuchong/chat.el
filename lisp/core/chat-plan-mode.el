;;; chat-plan-mode.el --- Read-only planning permission mode -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;;; Commentary:

;; Plan Mode is a permission boundary for research and plan approval.  It is
;; independent from durable Goals and from the work-plan/TODO artifact.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'chat-event)
(require 'chat-session)
(require 'chat-tool-forge)
(require 'chat-tool-caller)
(require 'chat-work-plan)
(require 'chat-work-context)

(defgroup chat-plan-mode nil
  "Read-only research and plan approval."
  :group 'chat)

(defcustom chat-plan-mode-max-feedback-chars 4096
  "Maximum retained user feedback for a rejected plan."
  :type 'integer :group 'chat-plan-mode)

(defconst chat-plan-mode-schema-version 1)
(defconst chat-plan-mode-statuses
  '(researching ready approved rejected cancelled))
(defconst chat-plan-mode--state-tool-prefixes
  '("programming_work_note_"))
(defconst chat-plan-mode--state-tools
  '("programming_context_inspect"
    "programming_goal_read" "programming_goal_list"
    "programming_goal_progress" "programming_goal_block"
    "programming_plan_create" "programming_plan_read"
    "programming_plan_list" "programming_plan_update"
    "programming_plan_submit"))
(defconst chat-plan-mode--ready-state-tools
  '("programming_goal_read" "programming_goal_list"
    "programming_plan_read" "programming_plan_list"
    "programming_work_note_query" "programming_context_inspect"))

(define-error 'chat-plan-mode-invalid "Invalid Plan Mode state")
(define-error 'chat-plan-mode-stale-revision "Stale Plan Mode revision")
(define-error 'chat-plan-mode-refused "Tool refused by Plan Mode")

(cl-defstruct
    (chat-plan-mode-state
     (:constructor chat-plan-mode-state-create
                   (&key (schema-version chat-plan-mode-schema-version)
                         (revision 1) (enabled t) (status 'researching)
                         plan-id plan-revision entered-at updated-at submitted-at
                         approved-at feedback metadata)))
  schema-version revision enabled status plan-id plan-revision entered-at updated-at
  submitted-at approved-at feedback metadata)

(defun chat-plan-mode--now ()
  "Return Unix time in milliseconds."
  (round (* 1000 (float-time))))

(defun chat-plan-mode--get (object key)
  "Return KEY from decoded alist OBJECT."
  (or (cdr (assoc key object))
      (and (symbolp key) (cdr (assoc (symbol-name key) object)))))

(defun chat-plan-mode--symbol (value)
  "Return VALUE as a symbol when possible."
  (cond ((symbolp value) value)
        ((and (stringp value) (not (string-empty-p value))) (intern value))))

(defun chat-plan-mode-to-alist (state)
  "Return JSON-safe representation of STATE."
  `((schemaVersion . ,(chat-plan-mode-state-schema-version state))
    (revision . ,(chat-plan-mode-state-revision state))
    (enabled . ,(if (chat-plan-mode-state-enabled state) t :json-false))
    (status . ,(symbol-name (chat-plan-mode-state-status state)))
    (planId . ,(chat-plan-mode-state-plan-id state))
    (planRevision . ,(chat-plan-mode-state-plan-revision state))
    (enteredAt . ,(chat-plan-mode-state-entered-at state))
    (updatedAt . ,(chat-plan-mode-state-updated-at state))
    (submittedAt . ,(chat-plan-mode-state-submitted-at state))
    (approvedAt . ,(chat-plan-mode-state-approved-at state))
    (feedback . ,(chat-plan-mode-state-feedback state))
    (metadata . ,(chat-plan-mode-state-metadata state))))

(defun chat-plan-mode-from-alist (data)
  "Decode and validate planning state DATA."
  (chat-plan-mode-validate
   (chat-plan-mode-state-create
    :schema-version (or (chat-plan-mode--get data 'schemaVersion) 1)
    :revision (or (chat-plan-mode--get data 'revision) 1)
    :enabled (not (eq (chat-plan-mode--get data 'enabled) :json-false))
    :status (or (chat-plan-mode--symbol (chat-plan-mode--get data 'status))
                'researching)
    :plan-id (chat-plan-mode--get data 'planId)
    :plan-revision (chat-plan-mode--get data 'planRevision)
    :entered-at (chat-plan-mode--get data 'enteredAt)
    :updated-at (chat-plan-mode--get data 'updatedAt)
    :submitted-at (chat-plan-mode--get data 'submittedAt)
    :approved-at (chat-plan-mode--get data 'approvedAt)
    :feedback (chat-plan-mode--get data 'feedback)
    :metadata (chat-plan-mode--get data 'metadata))))

(defun chat-plan-mode-validate (state)
  "Validate and return Plan Mode STATE."
  (unless (and (chat-plan-mode-state-p state)
               (= (or (chat-plan-mode-state-schema-version state) 0)
                  chat-plan-mode-schema-version)
               (integerp (chat-plan-mode-state-revision state))
               (> (chat-plan-mode-state-revision state) 0)
               (memq (chat-plan-mode-state-status state)
                     chat-plan-mode-statuses)
               (or (null (chat-plan-mode-state-plan-id state))
                   (stringp (chat-plan-mode-state-plan-id state)))
               (or (null (chat-plan-mode-state-plan-revision state))
                   (and (integerp
                         (chat-plan-mode-state-plan-revision state))
                        (> (chat-plan-mode-state-plan-revision state) 0)))
               (or (null (chat-plan-mode-state-feedback state))
                   (and (stringp (chat-plan-mode-state-feedback state))
                        (<= (length (chat-plan-mode-state-feedback state))
                            chat-plan-mode-max-feedback-chars))))
    (signal 'chat-plan-mode-invalid '("invalid planning state")))
  (when (and (eq (chat-plan-mode-state-status state) 'ready)
             (or (null (chat-plan-mode-state-plan-id state))
                 (null (chat-plan-mode-state-plan-revision state))))
    (signal 'chat-plan-mode-invalid
            '("ready Plan Mode needs a versioned plan")))
  (when (and (memq (chat-plan-mode-state-status state)
                   '(approved cancelled))
             (chat-plan-mode-state-enabled state))
    (signal 'chat-plan-mode-invalid '("terminal Plan Mode cannot be enabled")))
  state)

(defun chat-plan-mode-current (session)
  "Return SESSION's persisted Plan Mode state, or nil."
  (when-let ((data (chat-session-metadata-get session 'planModeV1)))
    (chat-plan-mode-from-alist data)))

(defun chat-plan-mode-active-p (session)
  "Return non-nil when SESSION is currently read-only planning."
  (when-let ((state (chat-plan-mode-current session)))
    (chat-plan-mode-state-enabled state)))

(defun chat-plan-mode--save (session state)
  "Persist STATE in SESSION and return it."
  (chat-plan-mode-validate state)
  (chat-session-metadata-set session 'planModeV1
                             (chat-plan-mode-to-alist state))
  (setf (chat-session-updated-at session) (current-time))
  (when (and (boundp 'chat-session-auto-save) chat-session-auto-save)
    (chat-session-save session))
  state)

(defun chat-plan-mode--emit (type session state &optional extra)
  "Emit bounded TYPE facts for SESSION, STATE and EXTRA."
  (chat-event-emit
   type :session-id (chat-session-id session) :source 'plan-mode
   :subject state
   :payload
   (append
    `((revision . ,(chat-plan-mode-state-revision state))
      (enabled . ,(and (chat-plan-mode-state-enabled state) t))
      (status . ,(symbol-name (chat-plan-mode-state-status state)))
      (planId . ,(chat-plan-mode-state-plan-id state))
      (planRevision . ,(chat-plan-mode-state-plan-revision state)))
    extra)))

(defun chat-plan-mode--check-revision (session state expected)
  "Refuse SESSION STATE when EXPECTED is stale."
  (unless (= expected (chat-plan-mode-state-revision state))
    (chat-plan-mode--emit 'plan-mode-conflicted session state)
    (signal 'chat-plan-mode-stale-revision
            (list (chat-plan-mode-state-revision state)))))

(defun chat-plan-mode-enter (session)
  "Enter a fresh read-only planning state for SESSION."
  (when (chat-plan-mode-active-p session)
    (signal 'chat-plan-mode-invalid '("Plan Mode is already active")))
  (let* ((now (chat-plan-mode--now))
         (state (chat-plan-mode-state-create
                 :revision 1 :enabled t :status 'researching
                 :entered-at now :updated-at now)))
    (chat-plan-mode--save session state)
    (chat-plan-mode--emit 'plan-mode-entered session state)
    state))

(defun chat-plan-mode--plan-submittable-p (plan)
  "Return non-nil when PLAN is a complete non-running proposal."
  (and plan
       (eq (chat-work-plan-status plan) 'active)
       (chat-work-plan-items plan)
       (seq-every-p
        (lambda (item)
          (and (eq (chat-work-plan-item-status item) 'pending)
               (stringp (chat-work-plan-item-acceptance item))
               (not (string-empty-p
                     (chat-work-plan-item-acceptance item)))))
        (chat-work-plan-items plan))))

(defun chat-plan-mode-submit (session plan-id expected-revision)
  "Submit PLAN-ID for user approval at EXPECTED-REVISION."
  (let ((state (or (chat-plan-mode-current session)
                   (signal 'chat-plan-mode-invalid '("Plan Mode is inactive")))))
    (chat-plan-mode--check-revision session state expected-revision)
    (unless (and (chat-plan-mode-state-enabled state)
                 (memq (chat-plan-mode-state-status state)
                       '(researching rejected)))
      (signal 'chat-plan-mode-invalid '("Plan Mode cannot submit")))
    (let ((plan (chat-work-plan-find session plan-id)))
      (unless (chat-plan-mode--plan-submittable-p plan)
        (signal 'chat-plan-mode-invalid
                '("plan needs pending items with acceptance criteria")))
      (setf (chat-plan-mode-state-plan-revision state)
            (chat-work-plan-revision plan)))
    (let ((now (chat-plan-mode--now)))
      (setf (chat-plan-mode-state-status state) 'ready
            (chat-plan-mode-state-plan-id state) plan-id
            (chat-plan-mode-state-revision state) (1+ expected-revision)
            (chat-plan-mode-state-submitted-at state) now
            (chat-plan-mode-state-updated-at state) now)
      (chat-plan-mode--save session state)
      (chat-plan-mode--emit 'plan-mode-submitted session state)
      state)))

(defun chat-plan-mode-approve (session expected-revision)
  "Approve SESSION's ready plan through a user-controlled path."
  (let ((state (or (chat-plan-mode-current session)
                   (signal 'chat-plan-mode-invalid '("Plan Mode is inactive")))))
    (chat-plan-mode--check-revision session state expected-revision)
    (unless (and (chat-plan-mode-state-enabled state)
                 (eq (chat-plan-mode-state-status state) 'ready))
      (signal 'chat-plan-mode-invalid '("no ready plan to approve")))
    (let ((plan (chat-work-plan-find
                 session (chat-plan-mode-state-plan-id state))))
      (unless (and (chat-plan-mode--plan-submittable-p plan)
                   (= (chat-work-plan-revision plan)
                      (chat-plan-mode-state-plan-revision state)))
        (signal 'chat-plan-mode-invalid
                '("submitted plan changed; revise and submit it again"))))
    (let ((now (chat-plan-mode--now)))
      (setf (chat-plan-mode-state-enabled state) nil
            (chat-plan-mode-state-status state) 'approved
            (chat-plan-mode-state-revision state) (1+ expected-revision)
            (chat-plan-mode-state-approved-at state) now
            (chat-plan-mode-state-updated-at state) now)
      (chat-plan-mode--save session state)
      (chat-plan-mode--emit 'plan-mode-approved session state)
      (chat-plan-mode--emit 'plan-mode-exited session state)
      state)))

(defun chat-plan-mode-reject (session expected-revision feedback)
  "Reject a ready plan and return to research with FEEDBACK."
  (let ((state (or (chat-plan-mode-current session)
                   (signal 'chat-plan-mode-invalid '("Plan Mode is inactive")))))
    (chat-plan-mode--check-revision session state expected-revision)
    (unless (and (chat-plan-mode-state-enabled state)
                 (eq (chat-plan-mode-state-status state) 'ready)
                 (stringp feedback) (not (string-empty-p feedback))
                 (<= (length feedback) chat-plan-mode-max-feedback-chars))
      (signal 'chat-plan-mode-invalid
              '("ready plan and bounded feedback are required")))
    (let ((now (chat-plan-mode--now)))
      (setf (chat-plan-mode-state-status state) 'researching
            (chat-plan-mode-state-feedback state) feedback
            (chat-plan-mode-state-revision state) (1+ expected-revision)
            (chat-plan-mode-state-updated-at state) now)
      (chat-plan-mode--save session state)
      (chat-plan-mode--emit 'plan-mode-rejected session state
                            '((hasFeedback . t)))
      state)))

(defun chat-plan-mode-cancel (session expected-revision)
  "Cancel SESSION's active Plan Mode at EXPECTED-REVISION."
  (let ((state (or (chat-plan-mode-current session)
                   (signal 'chat-plan-mode-invalid '("Plan Mode is inactive")))))
    (chat-plan-mode--check-revision session state expected-revision)
    (unless (chat-plan-mode-state-enabled state)
      (signal 'chat-plan-mode-invalid '("Plan Mode is not active")))
    (let ((now (chat-plan-mode--now)))
      (setf (chat-plan-mode-state-enabled state) nil
            (chat-plan-mode-state-status state) 'cancelled
            (chat-plan-mode-state-revision state) (1+ expected-revision)
            (chat-plan-mode-state-updated-at state) now)
      (chat-plan-mode--save session state)
      (chat-plan-mode--emit 'plan-mode-exited session state)
      state)))

(defun chat-plan-mode--state-tool-p (name state)
  "Return non-nil when NAME may mutate planning STATE only."
  (and (not (eq (chat-plan-mode-state-status state) 'ready))
       (or (member name chat-plan-mode--state-tools)
           (seq-some (lambda (prefix) (string-prefix-p prefix name))
                     chat-plan-mode--state-tool-prefixes))))

(defun chat-plan-mode--read-tool-p (call)
  "Return non-nil when CALL resolves to an explicitly read-only tool."
  (let* ((tool (chat-tool-caller-call-tool call))
         (effects (and tool (chat-forged-tool-effects tool))))
    (and tool effects
         (memq 'read effects)
         (seq-every-p (lambda (effect) (memq effect '(read outbound)))
                      effects))))

(defun chat-plan-mode-check-call (session call)
  "Return nil or a refusal reason for CALL in SESSION's Plan Mode."
  (when-let ((state (and session (chat-plan-mode-current session))))
    (when (chat-plan-mode-state-enabled state)
      (let* ((name (or (plist-get call :name) ""))
             (allowed
              (or (and (eq (chat-plan-mode-state-status state) 'ready)
                       (member name chat-plan-mode--ready-state-tools))
                  (chat-plan-mode--state-tool-p name state)
                  (chat-plan-mode--read-tool-p call))))
        (unless allowed
          (chat-plan-mode--emit
           'plan-mode-refused session state `((toolName . ,name)))
          (format
           "Plan Mode is read-only; tool `%s' is not allowed before user approval"
           name))))))

(defun chat-plan-mode-ui-projection (session)
  "Return stable UI projection for SESSION's planning state."
  (when-let ((state (chat-plan-mode-current session)))
    (list :revision (chat-plan-mode-state-revision state)
          :enabled (chat-plan-mode-state-enabled state)
          :status (chat-plan-mode-state-status state)
          :plan-id (chat-plan-mode-state-plan-id state)
          :plan-revision (chat-plan-mode-state-plan-revision state)
          :feedback (chat-plan-mode-state-feedback state))))

(defun chat-plan-mode-context-fragment (session)
  "Return SESSION's active Plan Mode as a protected context fragment."
  (when-let ((state (chat-plan-mode-current session)))
    (when (chat-plan-mode-state-enabled state)
      (let ((payload
             (string-join
              (delq
               nil
               (list
                (format "Plan Mode revision %d [%s]: read-only research boundary."
                        (chat-plan-mode-state-revision state)
                        (chat-plan-mode-state-status state))
                (if (eq (chat-plan-mode-state-status state) 'ready)
                    "A plan is waiting for user approval. Do not mutate it or execute work."
                  (format
                   "Research, maintain structured notes and a pending work plan, then submit it with planning revision %d. Do not edit source files or run commands."
                   (chat-plan-mode-state-revision state)))
                (and (chat-plan-mode-state-plan-id state)
                     (format "Current plan: %s revision %s"
                             (chat-plan-mode-state-plan-id state)
                             (or (chat-plan-mode-state-plan-revision state)
                                 "unsubmitted")))
                (and (chat-plan-mode-state-feedback state)
                     (format "User feedback: %s"
                             (chat-plan-mode-state-feedback state)))))
              "\n")))
        (chat-context-fragment-create
         :id (format "plan-mode-fragment:%s:%d"
                     (chat-session-id session)
                     (chat-plan-mode-state-revision state))
         :kind 'instruction :authority 'runtime :source-kind 'plan-mode
         :source-id (chat-session-id session) :scope 'session
         :scope-id (chat-session-id session)
         :priority 98 :residency 'protected :budget-policy 'preserve
         :payload (truncate-string-to-width payload 1200 nil nil t)
         :status 'active
         :metadata `((revision . ,(chat-plan-mode-state-revision state))))))))

(provide 'chat-plan-mode)
;;; chat-plan-mode.el ends here
