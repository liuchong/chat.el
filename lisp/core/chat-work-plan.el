;;; chat-work-plan.el --- Durable Agent work plans -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;;; Commentary:

;; Ordered TODO state belongs to the session and foreground task.  This module
;; owns the durable state machine, evidence links, mutation gate and bounded
;; projections; the chat UI only renders its public projection.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'chat-event)
(require 'chat-session)
(require 'chat-work-context)

(declare-function chat-task-get "chat-task" (id))
(declare-function chat-checkpoint-get "chat-checkpoint" (id &optional session-id))
(declare-function chat-code-verify-get "chat-code-verify" (id))
(declare-function chat-execution-get "chat-execution" (id))
(declare-function chat-session-wire-read-all "chat-session-wire" (session-id &optional kinds))
(declare-function chat-tool-caller-call-tool "chat-tool-caller" (call))
(declare-function chat-forged-tool-effects "chat-tool-forge" (tool))
(declare-function chat-task-id "chat-task" (task))
(declare-function chat-task-parent-id "chat-task" (task))
(declare-function chat-task-session-id "chat-task" (task))
(declare-function chat-checkpoint-session-id "chat-checkpoint" (checkpoint))
(declare-function chat-code-verify-result-session-id "chat-code-verify" (result))
(declare-function chat-code-verify-result-task-id "chat-code-verify" (result))
(declare-function chat-execution-record-request "chat-execution" (record))
(declare-function chat-execution-request-session-id "chat-execution" (request))
(declare-function chat-execution-request-task-id "chat-execution" (request))
(declare-function chat-goal-link-plan "chat-goal"
                  (session plan-id &optional message))

(defgroup chat-work-plan nil
  "Durable plans for substantial Agent work."
  :group 'chat)

(defcustom chat-work-plan-max-plans 32
  "Maximum retained plans in one session."
  :type 'integer :group 'chat-work-plan)

(defcustom chat-work-plan-max-items 64
  "Maximum items in one plan."
  :type 'integer :group 'chat-work-plan)

(defcustom chat-work-plan-max-text-chars 8192
  "Maximum objective, title, acceptance or blocker text size."
  :type 'integer :group 'chat-work-plan)

(defcustom chat-work-plan-max-projection-chars 2000
  "Maximum characters projected from one active plan into a request."
  :type 'integer :group 'chat-work-plan)

(defconst chat-work-plan-schema-version 1)
(defconst chat-work-plan-statuses '(active completed blocked cancelled))
(defconst chat-work-plan-item-statuses
  '(pending in-progress completed blocked skipped))
(defconst chat-work-plan-modes '(auto required off)
  "Accepted `mode' values on a plan record (schema compatibility only;
plan-mode enforcement itself was removed).")

(define-error 'chat-work-plan-invalid "Invalid work plan")
(define-error 'chat-work-plan-stale-revision "Stale work plan revision")

(cl-defstruct
    (chat-work-plan-item
     (:constructor chat-work-plan-item-create
                   (&key (schema-version chat-work-plan-schema-version)
                         id title order (status 'pending) dependencies
                         acceptance evidence started-at completed-at
                         blocker-reason metadata)))
  schema-version id title order status dependencies acceptance evidence
  started-at completed-at blocker-reason metadata)

(cl-defstruct
    (chat-work-plan
     (:constructor chat-work-plan-create-record
                   (&key (schema-version chat-work-plan-schema-version)
                         id (revision 1) session-id task-id objective
                         (mode 'auto) (status 'active) items created-at
                         updated-at completed-at metadata skip)))
  schema-version id revision session-id task-id objective mode status items
  created-at updated-at completed-at metadata skip)

(defvar chat-work-plan-evidence-resolver-functions nil
  "Functions called with SESSION, TASK-ID and EVIDENCE-ID.")

(defvar chat-work-plan--runtime-id
  (format "runtime-%s-%06x" (round (* 1000 (float-time))) (random #x1000000))
  "Identity of this Emacs runtime for interrupted-item recovery.")

(defun chat-work-plan--now ()
  "Return Unix time in milliseconds."
  (round (* 1000 (float-time))))

(defun chat-work-plan--symbol (value)
  "Return VALUE as a symbol when possible."
  (cond ((symbolp value) value)
        ((and (stringp value) (not (string-empty-p value))) (intern value))))

(defun chat-work-plan--get (object key)
  "Return KEY from decoded alist OBJECT."
  (or (cdr (assoc key object))
      (and (symbolp key) (cdr (assoc (symbol-name key) object)))))

(defun chat-work-plan--list (value)
  "Return vector or list VALUE as a list."
  (cond ((vectorp value) (append value nil))
        ((listp value) value)
        (t nil)))

(defun chat-work-plan--bounded-text-p (value &optional required)
  "Return non-nil when VALUE is bounded text, honoring REQUIRED."
  (and (or (not required) (and (stringp value) (not (string-empty-p value))))
       (or (null value)
           (and (stringp value)
                (<= (length value) chat-work-plan-max-text-chars)))))

(defun chat-work-plan--item-to-alist (item)
  "Return JSON-safe representation of ITEM."
  `((schemaVersion . ,(chat-work-plan-item-schema-version item))
    (id . ,(chat-work-plan-item-id item))
    (title . ,(chat-work-plan-item-title item))
    (order . ,(chat-work-plan-item-order item))
    (status . ,(symbol-name (chat-work-plan-item-status item)))
    (dependencies . ,(vconcat (or (chat-work-plan-item-dependencies item) nil)))
    (acceptance . ,(chat-work-plan-item-acceptance item))
    (evidence . ,(vconcat (or (chat-work-plan-item-evidence item) nil)))
    (startedAt . ,(chat-work-plan-item-started-at item))
    (completedAt . ,(chat-work-plan-item-completed-at item))
    (blockerReason . ,(chat-work-plan-item-blocker-reason item))
    (metadata . ,(chat-work-plan-item-metadata item))))

(defun chat-work-plan--item-from-alist (data)
  "Decode plan item DATA."
  (chat-work-plan-item-create
   :schema-version (or (chat-work-plan--get data 'schemaVersion) 1)
   :id (chat-work-plan--get data 'id)
   :title (chat-work-plan--get data 'title)
   :order (chat-work-plan--get data 'order)
   :status (or (chat-work-plan--symbol (chat-work-plan--get data 'status))
               'pending)
   :dependencies (chat-work-plan--list
                  (chat-work-plan--get data 'dependencies))
   :acceptance (chat-work-plan--get data 'acceptance)
   :evidence (chat-work-plan--list (chat-work-plan--get data 'evidence))
   :started-at (chat-work-plan--get data 'startedAt)
   :completed-at (chat-work-plan--get data 'completedAt)
   :blocker-reason (chat-work-plan--get data 'blockerReason)
   :metadata (chat-work-plan--get data 'metadata)))

(defun chat-work-plan-to-alist (plan)
  "Return JSON-safe representation of PLAN."
  `((schemaVersion . ,(chat-work-plan-schema-version plan))
    (id . ,(chat-work-plan-id plan))
    (revision . ,(chat-work-plan-revision plan))
    (sessionId . ,(chat-work-plan-session-id plan))
    (taskId . ,(chat-work-plan-task-id plan))
    (objective . ,(chat-work-plan-objective plan))
    (mode . ,(symbol-name (chat-work-plan-mode plan)))
    (status . ,(symbol-name (chat-work-plan-status plan)))
    (items . ,(vconcat (mapcar #'chat-work-plan--item-to-alist
                               (chat-work-plan-items plan))))
    (createdAt . ,(chat-work-plan-created-at plan))
    (updatedAt . ,(chat-work-plan-updated-at plan))
    (completedAt . ,(chat-work-plan-completed-at plan))
    (metadata . ,(chat-work-plan-metadata plan))
    (skip . ,(chat-work-plan-skip plan))))

(defun chat-work-plan-from-alist (data)
  "Decode and validate plan DATA."
  (chat-work-plan-validate
   (chat-work-plan-create-record
    :schema-version (or (chat-work-plan--get data 'schemaVersion) 1)
    :id (chat-work-plan--get data 'id)
    :revision (or (chat-work-plan--get data 'revision) 1)
    :session-id (chat-work-plan--get data 'sessionId)
    :task-id (chat-work-plan--get data 'taskId)
    :objective (chat-work-plan--get data 'objective)
    :mode (or (chat-work-plan--symbol (chat-work-plan--get data 'mode)) 'auto)
    :status (or (chat-work-plan--symbol (chat-work-plan--get data 'status)) 'active)
    :items (mapcar #'chat-work-plan--item-from-alist
                   (chat-work-plan--list (chat-work-plan--get data 'items)))
    :created-at (chat-work-plan--get data 'createdAt)
    :updated-at (chat-work-plan--get data 'updatedAt)
    :completed-at (chat-work-plan--get data 'completedAt)
    :metadata (chat-work-plan--get data 'metadata)
    :skip (chat-work-plan--get data 'skip))))

(defun chat-work-plan--metadata-value (plan key)
  "Return KEY from PLAN metadata."
  (chat-work-plan--get (chat-work-plan-metadata plan) key))

(defun chat-work-plan--metadata-set (plan key value)
  "Set KEY to VALUE in PLAN metadata."
  (setf (chat-work-plan-metadata plan)
        (cons (cons key value)
              (assq-delete-all key (copy-tree
                                    (or (chat-work-plan-metadata plan) nil))))))

(defun chat-work-plan--validate-dag (items)
  "Refuse missing dependencies and cycles in ITEMS."
  (let ((table (make-hash-table :test 'equal))
        (state (make-hash-table :test 'equal)))
    (dolist (item items)
      (when (gethash (chat-work-plan-item-id item) table)
        (signal 'chat-work-plan-invalid '("duplicate item id")))
      (puthash (chat-work-plan-item-id item) item table))
    (cl-labels
        ((visit (id)
           (pcase (gethash id state)
             ('visiting (signal 'chat-work-plan-invalid '("dependency cycle")))
             ('done nil)
             (_
              (let ((item (gethash id table)))
                (unless item
                  (signal 'chat-work-plan-invalid '("missing dependency")))
                (puthash id 'visiting state)
                (dolist (dependency (chat-work-plan-item-dependencies item))
                  (visit dependency))
                (puthash id 'done state))))))
      (maphash (lambda (id _item) (visit id)) table))))

(defun chat-work-plan-validate (plan)
  "Validate and return PLAN without consulting evidence stores."
  (unless (and (chat-work-plan-p plan)
               (= (or (chat-work-plan-schema-version plan) 0)
                  chat-work-plan-schema-version)
               (stringp (chat-work-plan-id plan))
               (stringp (chat-work-plan-session-id plan))
               (integerp (chat-work-plan-revision plan))
               (> (chat-work-plan-revision plan) 0)
               (chat-work-plan--bounded-text-p
                (chat-work-plan-objective plan) t)
               (memq (chat-work-plan-mode plan) chat-work-plan-modes)
               (memq (chat-work-plan-status plan) chat-work-plan-statuses))
    (signal 'chat-work-plan-invalid '("invalid plan header")))
  (let ((items (chat-work-plan-items plan)))
    (when (> (length items) chat-work-plan-max-items)
      (signal 'chat-work-plan-invalid '("too many plan items")))
    (when (and (eq (chat-work-plan-status plan) 'active)
               (null (chat-work-plan-skip plan))
               (null items))
      (signal 'chat-work-plan-invalid '("active plan has no items")))
    (dolist (item items)
      (unless (and (= (or (chat-work-plan-item-schema-version item) 0)
                          chat-work-plan-schema-version)
                   (stringp (chat-work-plan-item-id item))
                   (chat-work-plan--bounded-text-p
                    (chat-work-plan-item-title item) t)
                   (integerp (chat-work-plan-item-order item))
                   (memq (chat-work-plan-item-status item)
                         chat-work-plan-item-statuses)
                   (chat-work-plan--bounded-text-p
                    (chat-work-plan-item-acceptance item))
                   (chat-work-plan--bounded-text-p
                    (chat-work-plan-item-blocker-reason item)))
        (signal 'chat-work-plan-invalid '("invalid plan item")))
      (when (and (eq (chat-work-plan-item-status item) 'completed)
                 (null (chat-work-plan-item-evidence item)))
        (signal 'chat-work-plan-invalid '("completed item has no evidence")))
      (when (and (eq (chat-work-plan-item-status item) 'blocked)
                 (string-empty-p
                  (or (chat-work-plan-item-blocker-reason item) "")))
        (signal 'chat-work-plan-invalid '("blocked item has no reason"))))
    (when (> (seq-count (lambda (item)
                          (eq (chat-work-plan-item-status item) 'in-progress))
                        items)
             1)
      (signal 'chat-work-plan-invalid '("multiple in-progress items")))
    (chat-work-plan--validate-dag items))
  plan)

(defun chat-work-plan--session-plans (session)
  "Return every decoded plan stored in SESSION."
  (mapcar #'chat-work-plan-from-alist
          (chat-work-plan--list
           (chat-session-metadata-get session 'workPlans))))

(defun chat-work-plan--save (session plans active-id)
  "Atomically project PLANS and ACTIVE-ID into SESSION metadata."
  (setq plans
        (seq-take
         (sort plans (lambda (left right)
                       (> (or (chat-work-plan-updated-at left) 0)
                          (or (chat-work-plan-updated-at right) 0))))
         chat-work-plan-max-plans))
  (chat-session-metadata-set
   session 'workPlans (vconcat (mapcar #'chat-work-plan-to-alist plans)))
  (chat-session-metadata-set session 'activeWorkPlanId active-id)
  (setf (chat-session-updated-at session) (current-time))
  (when (and (boundp 'chat-session-auto-save) chat-session-auto-save)
    (chat-session-save session))
  plans)

(defun chat-work-plan--replace (session plan)
  "Persist PLAN in SESSION and return it."
  (let* ((plans (chat-work-plan--session-plans session))
         (rest (cl-remove (chat-work-plan-id plan) plans
                          :key #'chat-work-plan-id :test #'equal)))
    (chat-work-plan--save session (cons plan rest) (chat-work-plan-id plan))
    plan))

(defun chat-work-plan--emit (type plan &optional item extra)
  "Emit bounded TYPE facts for PLAN, ITEM and EXTRA."
  (chat-event-emit
   type :session-id (chat-work-plan-session-id plan)
   :task-id (chat-work-plan-task-id plan) :source 'work-plan
   :subject plan
   :payload
   (append
    `((planId . ,(chat-work-plan-id plan))
      (revision . ,(chat-work-plan-revision plan))
      (status . ,(symbol-name (chat-work-plan-status plan)))
      (itemCount . ,(length (chat-work-plan-items plan))))
    (when item
      `((itemId . ,(chat-work-plan-item-id item))
        (itemStatus . ,(symbol-name (chat-work-plan-item-status item)))
        (evidenceIds . ,(vconcat (or (chat-work-plan-item-evidence item) nil)))))
    extra)))

(defun chat-work-plan--notify-goal (session plan event)
  "Record PLAN lifecycle EVENT in SESSION's selected Goal, if active."
  (when (fboundp 'chat-goal-link-plan)
    (chat-goal-link-plan
     session (chat-work-plan-id plan)
     (format "Work plan lifecycle event: %s at revision %d."
             event (chat-work-plan-revision plan)))))

(defun chat-work-plan--active-task-id (session)
  "Return SESSION's foreground task id."
  (or (chat-session-metadata-get session 'activeTaskId)
      (chat-session-metadata-get session 'parentTaskId)))

(defun chat-work-plan--make-items (items)
  "Normalize decoded item descriptions ITEMS."
  (cl-loop for data in items
           for order from 0
           collect
           (chat-work-plan-item-create
            :id (or (chat-work-plan--get data 'id)
                    (chat-session-new-message-id "plan-item"))
            :title (chat-work-plan--get data 'title)
            :order order :status 'pending
            :dependencies
            (chat-work-plan--list (chat-work-plan--get data 'dependencies))
            :acceptance (chat-work-plan--get data 'acceptance)
            :evidence nil :metadata (chat-work-plan--get data 'metadata))))

(cl-defun chat-work-plan-create
    (session objective items &key mode task-id metadata)
  "Create and persist a plan for SESSION.

MODE is retained on the record for schema compatibility only; plan-mode
enforcement was removed and records are created with `off'."
  (let* ((now (chat-work-plan--now))
         (plan
          (chat-work-plan-create-record
           :id (chat-session-new-message-id "work-plan")
           :session-id (chat-session-id session)
           :task-id (or task-id (chat-work-plan--active-task-id session))
           :objective objective
           :mode (or mode 'off)
           :status 'active :items (chat-work-plan--make-items items)
           :created-at now :updated-at now
           :metadata (cons (cons 'runtimeId chat-work-plan--runtime-id)
                           (copy-tree metadata)))))
    (chat-work-plan-validate plan)
    (when-let ((current (chat-work-plan-current session nil)))
      (when (eq (chat-work-plan-status current) 'active)
        (signal 'chat-work-plan-invalid '("an active plan already exists"))))
    (chat-work-plan--replace session plan)
    (chat-work-plan--emit 'plan-created plan)
    (chat-work-plan--notify-goal session plan 'created)
    plan))

(defun chat-work-plan-find (session plan-id)
  "Return PLAN-ID stored in SESSION."
  (seq-find (lambda (plan) (equal plan-id (chat-work-plan-id plan)))
            (chat-work-plan--session-plans session)))

(defun chat-work-plan-list (session)
  "Return SESSION plans newest first as immutable decoded records."
  (mapcar #'chat-work-plan--clone (chat-work-plan--session-plans session)))

(defun chat-work-plan--same-task-p (left right)
  "Return non-nil when task identifiers LEFT and RIGHT have the same scope."
  (equal left right))

(defun chat-work-plan--recover (session plan)
  "Block an interrupted active item in PLAN after restart."
  (when (and (eq (chat-work-plan-status plan) 'active)
             (not (equal (chat-work-plan--metadata-value plan 'runtimeId)
                         chat-work-plan--runtime-id)))
    (when-let ((item (seq-find
                      (lambda (candidate)
                        (eq (chat-work-plan-item-status candidate) 'in-progress))
                      (chat-work-plan-items plan))))
      (setf (chat-work-plan-item-status item) 'blocked
            (chat-work-plan-item-blocker-reason item) "interrupted"
            (chat-work-plan-status plan) 'blocked
            (chat-work-plan-revision plan) (1+ (chat-work-plan-revision plan))
            (chat-work-plan-updated-at plan) (chat-work-plan--now))
      (chat-work-plan--metadata-set plan 'runtimeId chat-work-plan--runtime-id)
      (chat-work-plan--replace session plan)
      (chat-work-plan--emit 'plan-item-blocked plan item
                            '((reason . "interrupted")))
      (chat-work-plan--notify-goal session plan 'interrupted)))
  plan)

(defun chat-work-plan-current (session &optional recover)
  "Return SESSION's selected plan, optionally applying restart RECOVER."
  (when-let* ((id (chat-session-metadata-get session 'activeWorkPlanId))
              (plan (chat-work-plan-find session id)))
    (if recover (chat-work-plan--recover session plan) plan)))

(defun chat-work-plan--clone (plan)
  "Return a deep copy of PLAN."
  (chat-work-plan-from-alist (chat-work-plan-to-alist plan)))

(defun chat-work-plan--item (plan item-id)
  "Return ITEM-ID from PLAN or signal."
  (or (seq-find (lambda (item)
                  (equal item-id (chat-work-plan-item-id item)))
                (chat-work-plan-items plan))
      (signal 'chat-work-plan-invalid '("unknown plan item"))))

(defun chat-work-plan--check-revision (plan expected)
  "Refuse PLAN when EXPECTED is stale."
  (unless (= expected (chat-work-plan-revision plan))
    (chat-work-plan--emit 'plan-revision-conflict plan)
    (signal 'chat-work-plan-stale-revision
            (list (chat-work-plan-revision plan)))))

(defun chat-work-plan--dependencies-ready-p (plan item)
  "Return non-nil when ITEM dependencies in PLAN are terminal-success."
  (seq-every-p
   (lambda (id)
     (memq (chat-work-plan-item-status (chat-work-plan--item plan id))
           '(completed skipped)))
   (chat-work-plan-item-dependencies item)))

(defun chat-work-plan--evidence-syntax-p (id)
  "Return non-nil when evidence ID is bounded and namespaced."
  (and (stringp id) (<= (length id) 256)
       (string-match-p "\\`[[:alnum:]][[:alnum:]_.:-]+\\'" id)))

(defun chat-work-plan--evidence-scope-p
    (session task-id record-session-id record-task-id)
  "Return non-nil when one evidence record belongs to SESSION and TASK-ID."
  (and (equal record-session-id (chat-session-id session))
       (or (null task-id) (null record-task-id)
           (equal task-id record-task-id))))

(defun chat-work-plan--default-evidence-known-p (session task-id id)
  "Resolve ID through existing runtime stores for SESSION."
  (or (and (fboundp 'chat-task-get)
           (when-let ((task (ignore-errors (chat-task-get id))))
             (and (chat-work-plan--evidence-scope-p
                   session task-id (chat-task-session-id task)
                   (chat-task-id task))
                  (or (null task-id)
                      (equal task-id (chat-task-id task))
                      (equal task-id (chat-task-parent-id task))))))
      (and (fboundp 'chat-checkpoint-get)
           (when-let ((checkpoint
                       (ignore-errors
                         (chat-checkpoint-get id (chat-session-id session)))))
             (chat-work-plan--evidence-scope-p
              session task-id (chat-checkpoint-session-id checkpoint) nil)))
      (and (fboundp 'chat-code-verify-get)
           (when-let ((result (ignore-errors (chat-code-verify-get id))))
             (chat-work-plan--evidence-scope-p
              session task-id (chat-code-verify-result-session-id result)
              (chat-code-verify-result-task-id result))))
      (and (fboundp 'chat-execution-get)
           (when-let* ((record (ignore-errors (chat-execution-get id)))
                       (request (chat-execution-record-request record)))
             (chat-work-plan--evidence-scope-p
              session task-id (chat-execution-request-session-id request)
              (chat-execution-request-task-id request))))
      (and (fboundp 'chat-session-wire-read-all)
           (seq-some
            (lambda (record)
              (let ((record-task-id
                     (or (chat-work-plan--get record 'agent_task_id)
                         (chat-work-plan--get record 'task_id))))
                (and (equal id (or (chat-work-plan--get record 'event_id)
                                   (chat-work-plan--get record 'id)))
                     (or (null task-id)
                         (null record-task-id)
                         (equal task-id record-task-id)))))
            (ignore-errors
              (chat-session-wire-read-all (chat-session-id session)))))))

(defun chat-work-plan-evidence-known-p (session task-id id)
  "Return non-nil when ID resolves for SESSION and TASK-ID."
  (and (chat-work-plan--evidence-syntax-p id)
       (or (chat-work-plan--default-evidence-known-p session task-id id)
           (seq-some (lambda (resolver)
                       (funcall resolver session task-id id))
                     chat-work-plan-evidence-resolver-functions))))

(defun chat-work-plan--finalize-if-done (plan)
  "Complete PLAN when every item is completed or skipped."
  (when (and (chat-work-plan-items plan)
             (seq-every-p
              (lambda (item)
                (memq (chat-work-plan-item-status item) '(completed skipped)))
              (chat-work-plan-items plan)))
    (setf (chat-work-plan-status plan) 'completed
          (chat-work-plan-completed-at plan) (chat-work-plan--now)))
  plan)

(cl-defun chat-work-plan-transition-item
    (session plan-id expected-revision item-id status
             &key evidence blocker-reason)
  "Transition ITEM-ID in PLAN-ID using EXPECTED-REVISION."
  (let* ((original (or (chat-work-plan-find session plan-id)
                       (signal 'chat-work-plan-invalid '("unknown plan"))))
         (plan (chat-work-plan--clone original)))
    (chat-work-plan--check-revision plan expected-revision)
    (when (memq (chat-work-plan-status plan) '(completed cancelled))
      (signal 'chat-work-plan-invalid '("terminal plan cannot change")))
    (let* ((item (chat-work-plan--item plan item-id))
           (old (chat-work-plan-item-status item))
           (now (chat-work-plan--now)))
      (unless (memq status chat-work-plan-item-statuses)
        (signal 'chat-work-plan-invalid '("invalid item status")))
      (pcase status
        ('in-progress
         (unless (and (eq old 'pending)
                      (chat-work-plan--dependencies-ready-p plan item)
                      (not (seq-some
                            (lambda (other)
                              (and (not (eq other item))
                                   (eq (chat-work-plan-item-status other)
                                       'in-progress)))
                            (chat-work-plan-items plan))))
           (signal 'chat-work-plan-invalid '("item cannot start")))
         (setf (chat-work-plan-item-started-at item) now
               (chat-work-plan-item-blocker-reason item) nil
               (chat-work-plan-status plan) 'active))
       ('completed
         (unless (eq old 'in-progress)
           (signal 'chat-work-plan-invalid '("only active item can complete")))
         (let ((unknown
                (seq-remove
                 (lambda (id)
                   (chat-work-plan-evidence-known-p
                    session (chat-work-plan-task-id plan) id))
                 evidence)))
           (unless (and evidence (null unknown))
             (signal
              'chat-work-plan-invalid
              (list
               (if unknown
                   (format
                    "completion evidence unknown: %s; use exact evidenceId from a successful tool result"
                    (string-join (seq-take unknown 5) ", "))
                 "completion evidence required; use exact evidenceId from a successful tool result")))))
         (setf (chat-work-plan-item-evidence item) (delete-dups evidence)
               (chat-work-plan-item-completed-at item) now
               (chat-work-plan-item-metadata item)
               (cons (cons 'completedRevision (1+ expected-revision))
                     (assq-delete-all
                      'completedRevision
                      (copy-tree
                       (or (chat-work-plan-item-metadata item) nil))))))
        ('blocked
         (unless (and (memq old '(pending in-progress))
                      (chat-work-plan--bounded-text-p blocker-reason t))
           (signal 'chat-work-plan-invalid '("blocker reason required")))
         (setf (chat-work-plan-item-blocker-reason item) blocker-reason
               (chat-work-plan-status plan) 'blocked))
        ('skipped
         (unless (eq old 'pending)
           (signal 'chat-work-plan-invalid '("only pending item can skip"))))
        (_ (signal 'chat-work-plan-invalid '("use resume for pending"))))
      (setf (chat-work-plan-item-status item) status
            (chat-work-plan-revision plan) (1+ expected-revision)
            (chat-work-plan-updated-at plan) now)
      (chat-work-plan--finalize-if-done plan)
      (chat-work-plan-validate plan)
      (chat-work-plan--replace session plan)
      (chat-work-plan--emit
       (pcase status
         ('in-progress 'plan-item-started)
         ('completed 'plan-item-completed)
         ('blocked 'plan-item-blocked)
         ('skipped 'plan-item-skipped))
       plan item
       (when blocker-reason '((hasReason . t))))
      (when (eq (chat-work-plan-status plan) 'completed)
        (chat-work-plan--emit 'plan-completed plan))
      (chat-work-plan--notify-goal session plan status)
      plan)))

(defun chat-work-plan-start-first-ready
    (session plan-id expected-revision)
  "Start the earliest dependency-ready pending item in PLAN-ID.

EXPECTED-REVISION keeps this compound convenience operation under the same
optimistic concurrency contract as every explicit item transition."
  (let ((plan (or (chat-work-plan-find session plan-id)
                  (signal 'chat-work-plan-invalid '("unknown plan")))))
    (chat-work-plan--check-revision plan expected-revision)
    (when (chat-work-plan--in-progress-item plan)
      (signal 'chat-work-plan-invalid '("plan already has an active item")))
    (let ((item
           (seq-find
            (lambda (candidate)
              (and (eq (chat-work-plan-item-status candidate) 'pending)
                   (chat-work-plan--dependencies-ready-p plan candidate)))
            (chat-work-plan-items plan))))
      (unless item
        (signal 'chat-work-plan-invalid '("no dependency-ready item")))
      (chat-work-plan-transition-item
       session plan-id expected-revision (chat-work-plan-item-id item)
       'in-progress))))

(defun chat-work-plan-resume (session plan-id expected-revision)
  "Resume blocked PLAN-ID at EXPECTED-REVISION."
  (let* ((original (or (chat-work-plan-find session plan-id)
                       (signal 'chat-work-plan-invalid '("unknown plan"))))
         (plan (chat-work-plan--clone original)))
    (chat-work-plan--check-revision plan expected-revision)
    (unless (eq (chat-work-plan-status plan) 'blocked)
      (signal 'chat-work-plan-invalid '("plan is not blocked")))
    (when-let ((item (seq-find
                      (lambda (candidate)
                        (eq (chat-work-plan-item-status candidate) 'blocked))
                      (chat-work-plan-items plan))))
      (setf (chat-work-plan-item-status item) 'pending
            (chat-work-plan-item-blocker-reason item) nil))
    (setf (chat-work-plan-status plan) 'active
          (chat-work-plan-revision plan) (1+ expected-revision)
          (chat-work-plan-updated-at plan) (chat-work-plan--now))
    (chat-work-plan--metadata-set plan 'runtimeId chat-work-plan--runtime-id)
    (chat-work-plan--replace session plan)
    (chat-work-plan--emit 'plan-resumed plan)
    (chat-work-plan--notify-goal session plan 'resumed)
    plan))

(defun chat-work-plan-cancel (session plan-id expected-revision)
  "Cancel PLAN-ID at EXPECTED-REVISION."
  (let* ((original (or (chat-work-plan-find session plan-id)
                       (signal 'chat-work-plan-invalid '("unknown plan"))))
         (plan (chat-work-plan--clone original)))
    (chat-work-plan--check-revision plan expected-revision)
    (when (memq (chat-work-plan-status plan) '(completed cancelled))
      (signal 'chat-work-plan-invalid '("plan is terminal")))
    (setf (chat-work-plan-status plan) 'cancelled
          (chat-work-plan-revision plan) (1+ expected-revision)
          (chat-work-plan-updated-at plan) (chat-work-plan--now))
    (chat-work-plan--replace session plan)
    (chat-work-plan--emit 'plan-cancelled plan)
    (chat-work-plan--notify-goal session plan 'cancelled)
    plan))

(cl-defun chat-work-plan-update-future
    (session plan-id expected-revision items &key objective)
  "Replace the unstarted future ITEMS in PLAN-ID at EXPECTED-REVISION.
Started, completed, blocked and skipped items are immutable history."
  (let* ((original (or (chat-work-plan-find session plan-id)
                       (signal 'chat-work-plan-invalid '("unknown plan"))))
         (plan (chat-work-plan--clone original)))
    (chat-work-plan--check-revision plan expected-revision)
    (unless (memq (chat-work-plan-status plan) '(active blocked))
      (signal 'chat-work-plan-invalid '("terminal plan cannot change")))
    (let* ((fixed (seq-filter
                   (lambda (item)
                     (not (eq (chat-work-plan-item-status item) 'pending)))
                   (chat-work-plan-items plan)))
           (future (chat-work-plan--make-items items))
           (offset (length fixed))
           (now (chat-work-plan--now)))
      (cl-loop for item in future
               for order from offset
               do (setf (chat-work-plan-item-order item) order))
      (cl-loop for item in fixed
               for order from 0
               do (setf (chat-work-plan-item-order item) order))
      (when objective
        (unless (chat-work-plan--bounded-text-p objective t)
          (signal 'chat-work-plan-invalid '("invalid plan objective")))
        (setf (chat-work-plan-objective plan) objective))
      (setf (chat-work-plan-items plan) (append fixed future)
            (chat-work-plan-revision plan) (1+ expected-revision)
            (chat-work-plan-updated-at plan) now)
      (chat-work-plan-validate plan)
      (chat-work-plan--replace session plan)
      (chat-work-plan--emit
       'plan-updated plan nil
       `((preservedItemCount . ,(length fixed))
         (futureItemCount . ,(length future))))
      (chat-work-plan--notify-goal session plan 'updated)
      plan)))

(defun chat-work-plan--in-progress-item (plan)
  "Return PLAN's single in-progress item, if any."
  (seq-find (lambda (item)
              (eq (chat-work-plan-item-status item) 'in-progress))
            (chat-work-plan-items plan)))

(defun chat-work-plan-active-slice (plan)
  "Return a bounded public active projection for PLAN."
  (let* ((items (chat-work-plan-items plan))
         (done (seq-count
                (lambda (item)
                  (memq (chat-work-plan-item-status item) '(completed skipped)))
                items))
         (current (or (seq-find
                       (lambda (item)
                         (eq (chat-work-plan-item-status item) 'in-progress))
                       items)
                      (seq-find
                       (lambda (item)
                         (eq (chat-work-plan-item-status item) 'blocked))
                       items)
                      (seq-find
                       (lambda (item)
                         (eq (chat-work-plan-item-status item) 'pending))
                       items))))
    (list :plan-id (chat-work-plan-id plan)
          :revision (chat-work-plan-revision plan)
          :status (chat-work-plan-status plan)
          :objective (chat-work-plan-objective plan)
          :completed done :total (length items)
          :current-index (and current (1+ (chat-work-plan-item-order current)))
          :current-item current
          :incomplete-dependencies
          (and current
               (mapcar
                (lambda (id)
                  (chat-work-plan--item plan id))
                (seq-filter
                 (lambda (id)
                   (not (memq
                         (chat-work-plan-item-status
                          (chat-work-plan--item plan id))
                         '(completed skipped))))
                 (chat-work-plan-item-dependencies current))))
          :remaining
          (mapcar #'chat-work-plan-item-title
                  (seq-filter
                   (lambda (item)
                     (and (not (eq item current))
                          (memq (chat-work-plan-item-status item)
                                '(pending in-progress blocked))))
                   items)))))

(defun chat-work-plan-context-fragment
    (session &optional task-id since-revision)
  "Return SESSION's active plan as one task-scoped context fragment."
  (when-let* ((plan (chat-work-plan-current session t))
              ((or (null task-id) (null (chat-work-plan-task-id plan))
                   (equal task-id (chat-work-plan-task-id plan))))
              ((memq (chat-work-plan-status plan) '(active blocked)))
              (slice (chat-work-plan-active-slice plan)))
    (let* ((item (plist-get slice :current-item))
           (new-evidence
            (and since-revision
                 (apply
                  #'append
                  (mapcar
                   (lambda (candidate)
                     (and (> (or (chat-work-plan--get
                                  (chat-work-plan-item-metadata candidate)
                                  'completedRevision)
                                 0)
                             since-revision)
                          (copy-sequence
                           (or (chat-work-plan-item-evidence candidate) nil))))
                   (chat-work-plan-items plan)))))
           (payload
            (string-join
             (delq nil
                   (list
                    (format "Work plan %s revision %d: %s"
                            (chat-work-plan-id plan)
                            (chat-work-plan-revision plan)
                            (chat-work-plan-objective plan))
                    (and item
                         (format "Current item %d/%d: %s"
                                 (plist-get slice :current-index)
                                 (plist-get slice :total)
                                 (chat-work-plan-item-title item)))
                    (and item (chat-work-plan-item-acceptance item)
                         (format "Acceptance: %s"
                                 (chat-work-plan-item-acceptance item)))
                    (when-let ((dependencies
                                (plist-get slice :incomplete-dependencies)))
                      (format "Waiting on: %s"
                              (mapconcat #'chat-work-plan-item-title
                                         dependencies "; ")))
                    (and item (chat-work-plan-item-blocker-reason item)
                         (format "Blocker: %s"
                                 (chat-work-plan-item-blocker-reason item)))
                    (when-let ((remaining
                                (seq-take (plist-get slice :remaining) 5)))
                      (format "Remaining: %s"
                              (mapconcat #'identity remaining "; ")))
                    (and new-evidence
                         (format "New evidence: %s"
                                 (mapconcat #'identity new-evidence "; ")))
                    (format "Progress: %d/%d completed"
                            (plist-get slice :completed)
                            (plist-get slice :total))))
             "\n")))
      (chat-context-fragment-create
       :id (format "plan-fragment:%s:%d"
                   (chat-work-plan-id plan) (chat-work-plan-revision plan))
       :kind 'objective :authority 'runtime :source-kind 'work-plan
       :source-id (chat-work-plan-id plan)
       :scope (if (chat-work-plan-task-id plan) 'task 'session)
       :scope-id (or (chat-work-plan-task-id plan) (chat-session-id session))
       :priority 90 :residency 'protected :budget-policy 'preserve
       :payload (truncate-string-to-width
                 payload chat-work-plan-max-projection-chars nil nil t)
       :status 'active
       :metadata `((revision . ,(chat-work-plan-revision plan)))))))

(defun chat-work-plan-ui-projection (session)
  "Return SESSION's selected plan projection for native UI rendering."
  (when-let ((plan (chat-work-plan-current session t)))
    (append (chat-work-plan-active-slice plan)
            (list :items (chat-work-plan-items plan)
                  :skip (chat-work-plan-skip plan)))))

(provide 'chat-work-plan)
;;; chat-work-plan.el ends here
