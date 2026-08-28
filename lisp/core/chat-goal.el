;;; chat-goal.el --- Durable cross-turn goals -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;;; Commentary:

;; A Goal is a durable completion contract, not an execution plan.  This
;; module owns its lifecycle, optimistic revisions, evidence validation,
;; legacy migration and bounded context/UI projections.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'chat-event)
(require 'chat-session)
(require 'chat-work-context)
(require 'chat-work-plan)

(defgroup chat-goal nil
  "Durable cross-turn task goals."
  :group 'chat)

(defcustom chat-goal-max-goals 24
  "Maximum retained Goal records in one session."
  :type 'integer :group 'chat-goal)

(defcustom chat-goal-max-criteria 32
  "Maximum success criteria in one Goal."
  :type 'integer :group 'chat-goal)

(defcustom chat-goal-max-links 64
  "Maximum plan, task or evidence links in one Goal."
  :type 'integer :group 'chat-goal)

(defcustom chat-goal-max-progress-entries 64
  "Maximum recent progress entries retained in one Goal."
  :type 'integer :group 'chat-goal)

(defcustom chat-goal-max-text-chars 8192
  "Maximum size of one Goal text field."
  :type 'integer :group 'chat-goal)

(defcustom chat-goal-max-projection-chars 2400
  "Maximum Goal characters projected into one request."
  :type 'integer :group 'chat-goal)

(defcustom chat-goal-max-continuations-per-run 4
  "Maximum automatic Goal continuations after natural model stops."
  :type 'integer :group 'chat-goal)

(defconst chat-goal-schema-version 1)
(defconst chat-goal-statuses '(active paused blocked completed cancelled))
(defconst chat-goal-criterion-statuses '(pending satisfied))
(defconst chat-goal-terminal-statuses '(completed cancelled))
(defconst chat-goal-verification-predicates '(all-required-criteria))

(define-error 'chat-goal-invalid "Invalid Goal")
(define-error 'chat-goal-stale-revision "Stale Goal revision")
(define-error 'chat-goal-transition-invalid "Invalid Goal transition")
(define-error 'chat-goal-evidence-invalid "Invalid Goal evidence")
(define-error 'chat-goal-scope-mismatch "Goal is outside the current project scope")

(cl-defstruct
    (chat-goal-criterion
     (:constructor chat-goal-criterion-create
                   (&key (schema-version chat-goal-schema-version)
                         id title (required t) (status 'pending)
                         evidence satisfied-at metadata)))
  schema-version id title required status evidence satisfied-at metadata)

(cl-defstruct
    (chat-goal
     (:constructor chat-goal-create-record
                   (&key (schema-version chat-goal-schema-version)
                         id (revision 1) session-id project-root objective
                         success-criteria constraints non-goals sources
                         stopping-condition verification-spec (status 'active)
                         current-checkpoint evidence progress-log blocker-reason
                         unblock-condition plan-ids active-plan-id task-ids
                         created-at updated-at paused-at blocked-at completed-at
                         metadata)))
  schema-version id revision session-id project-root objective success-criteria
  constraints non-goals sources stopping-condition verification-spec status
  current-checkpoint evidence progress-log blocker-reason unblock-condition
  plan-ids active-plan-id task-ids created-at updated-at paused-at blocked-at
  completed-at metadata)

(defun chat-goal--now ()
  "Return Unix time in milliseconds."
  (round (* 1000 (float-time))))

(defun chat-goal--get (object key)
  "Return KEY from decoded alist OBJECT."
  (or (cdr (assoc key object))
      (and (symbolp key) (cdr (assoc (symbol-name key) object)))))

(defun chat-goal--symbol (value)
  "Return VALUE as a symbol when possible."
  (cond ((symbolp value) value)
        ((and (stringp value) (not (string-empty-p value))) (intern value))))

(defun chat-goal--list (value)
  "Return vector or list VALUE as a list."
  (cond ((vectorp value) (append value nil))
        ((listp value) value)
        (t nil)))

(defun chat-goal--bounded-text-p (value &optional required)
  "Return non-nil when VALUE is bounded text, honoring REQUIRED."
  (and (or (not required)
           (and (stringp value) (not (string-empty-p value))))
       (or (null value)
           (and (stringp value)
                (<= (length value) chat-goal-max-text-chars)))))

(defun chat-goal--bounded-text-list-p (values)
  "Return non-nil when VALUES is a bounded list of bounded strings."
  (and (<= (length values) chat-goal-max-links)
       (seq-every-p (lambda (value) (chat-goal--bounded-text-p value t))
                    values)))

(defun chat-goal--bool (value &optional default)
  "Normalize JSON VALUE to boolean, using DEFAULT for nil."
  (cond ((eq value :json-false) nil)
        ((null value) default)
        (t t)))

(defun chat-goal--criterion-to-alist (criterion)
  "Return JSON-safe representation of CRITERION."
  `((schemaVersion . ,(chat-goal-criterion-schema-version criterion))
    (id . ,(chat-goal-criterion-id criterion))
    (title . ,(chat-goal-criterion-title criterion))
    (required . ,(if (chat-goal-criterion-required criterion) t :json-false))
    (status . ,(symbol-name (chat-goal-criterion-status criterion)))
    (evidence . ,(vconcat (or (chat-goal-criterion-evidence criterion) nil)))
    (satisfiedAt . ,(chat-goal-criterion-satisfied-at criterion))
    (metadata . ,(chat-goal-criterion-metadata criterion))))

(defun chat-goal--criterion-from-alist (data)
  "Decode criterion DATA."
  (chat-goal-criterion-create
   :schema-version (or (chat-goal--get data 'schemaVersion) 1)
   :id (chat-goal--get data 'id)
   :title (chat-goal--get data 'title)
   :required (chat-goal--bool (chat-goal--get data 'required) t)
   :status (or (chat-goal--symbol (chat-goal--get data 'status)) 'pending)
   :evidence (chat-goal--list (chat-goal--get data 'evidence))
   :satisfied-at (chat-goal--get data 'satisfiedAt)
   :metadata (chat-goal--get data 'metadata)))

(defun chat-goal-to-alist (goal)
  "Return JSON-safe representation of GOAL."
  `((schemaVersion . ,(chat-goal-schema-version goal))
    (id . ,(chat-goal-id goal))
    (revision . ,(chat-goal-revision goal))
    (sessionId . ,(chat-goal-session-id goal))
    (projectRoot . ,(chat-goal-project-root goal))
    (objective . ,(chat-goal-objective goal))
    (successCriteria . ,(vconcat
                         (mapcar #'chat-goal--criterion-to-alist
                                 (chat-goal-success-criteria goal))))
    (constraints . ,(vconcat (or (chat-goal-constraints goal) nil)))
    (nonGoals . ,(vconcat (or (chat-goal-non-goals goal) nil)))
    (sources . ,(vconcat (or (chat-goal-sources goal) nil)))
    (stoppingCondition . ,(chat-goal-stopping-condition goal))
    (verificationSpec . ,(chat-goal-verification-spec goal))
    (status . ,(symbol-name (chat-goal-status goal)))
    (currentCheckpoint . ,(chat-goal-current-checkpoint goal))
    (evidence . ,(vconcat (or (chat-goal-evidence goal) nil)))
    (progressLog . ,(vconcat (or (chat-goal-progress-log goal) nil)))
    (blockerReason . ,(chat-goal-blocker-reason goal))
    (unblockCondition . ,(chat-goal-unblock-condition goal))
    (planIds . ,(vconcat (or (chat-goal-plan-ids goal) nil)))
    (activePlanId . ,(chat-goal-active-plan-id goal))
    (taskIds . ,(vconcat (or (chat-goal-task-ids goal) nil)))
    (createdAt . ,(chat-goal-created-at goal))
    (updatedAt . ,(chat-goal-updated-at goal))
    (pausedAt . ,(chat-goal-paused-at goal))
    (blockedAt . ,(chat-goal-blocked-at goal))
    (completedAt . ,(chat-goal-completed-at goal))
    (metadata . ,(chat-goal-metadata goal))))

(defun chat-goal-from-alist (data)
  "Decode and validate Goal DATA."
  (chat-goal-validate
   (chat-goal-create-record
    :schema-version (or (chat-goal--get data 'schemaVersion) 1)
    :id (chat-goal--get data 'id)
    :revision (or (chat-goal--get data 'revision) 1)
    :session-id (chat-goal--get data 'sessionId)
    :project-root (chat-goal--get data 'projectRoot)
    :objective (chat-goal--get data 'objective)
    :success-criteria
    (mapcar #'chat-goal--criterion-from-alist
            (chat-goal--list (chat-goal--get data 'successCriteria)))
    :constraints (chat-goal--list (chat-goal--get data 'constraints))
    :non-goals (chat-goal--list (chat-goal--get data 'nonGoals))
    :sources (chat-goal--list (chat-goal--get data 'sources))
    :stopping-condition (chat-goal--get data 'stoppingCondition)
    :verification-spec (chat-goal--get data 'verificationSpec)
    :status (or (chat-goal--symbol (chat-goal--get data 'status)) 'active)
    :current-checkpoint (chat-goal--get data 'currentCheckpoint)
    :evidence (chat-goal--list (chat-goal--get data 'evidence))
    :progress-log (chat-goal--list (chat-goal--get data 'progressLog))
    :blocker-reason (chat-goal--get data 'blockerReason)
    :unblock-condition (chat-goal--get data 'unblockCondition)
    :plan-ids (chat-goal--list (chat-goal--get data 'planIds))
    :active-plan-id (chat-goal--get data 'activePlanId)
    :task-ids (chat-goal--list (chat-goal--get data 'taskIds))
    :created-at (chat-goal--get data 'createdAt)
    :updated-at (chat-goal--get data 'updatedAt)
    :paused-at (chat-goal--get data 'pausedAt)
    :blocked-at (chat-goal--get data 'blockedAt)
    :completed-at (chat-goal--get data 'completedAt)
    :metadata (chat-goal--get data 'metadata))))

(defun chat-goal--verification-predicate (goal)
  "Return GOAL's deterministic verification predicate."
  (or (chat-goal--symbol
       (chat-goal--get (chat-goal-verification-spec goal) 'predicate))
      'all-required-criteria))

(defun chat-goal--metadata-set (goal key value)
  "Set KEY to VALUE in GOAL metadata."
  (setf (chat-goal-metadata goal)
        (cons (cons key value)
              (assq-delete-all key (copy-tree (chat-goal-metadata goal))))))

(defun chat-goal-validate (goal)
  "Validate and return GOAL without consulting evidence stores."
  (unless (and (chat-goal-p goal)
               (= (or (chat-goal-schema-version goal) 0)
                  chat-goal-schema-version)
               (stringp (chat-goal-id goal))
               (stringp (chat-goal-session-id goal))
               (integerp (chat-goal-revision goal))
               (> (chat-goal-revision goal) 0)
               (chat-goal--bounded-text-p (chat-goal-objective goal) t)
               (chat-goal--bounded-text-p
                (chat-goal-stopping-condition goal) t)
               (memq (chat-goal-status goal) chat-goal-statuses)
               (memq (chat-goal--verification-predicate goal)
                     chat-goal-verification-predicates))
    (signal 'chat-goal-invalid '("invalid Goal header")))
  (let ((criteria (chat-goal-success-criteria goal)))
    (unless (and criteria (<= (length criteria) chat-goal-max-criteria))
      (signal 'chat-goal-invalid '("Goal requires success criteria")))
    (let ((ids (make-hash-table :test 'equal)))
      (dolist (criterion criteria)
        (unless (and (= (or (chat-goal-criterion-schema-version criterion) 0)
                            chat-goal-schema-version)
                     (stringp (chat-goal-criterion-id criterion))
                     (chat-goal--bounded-text-p
                      (chat-goal-criterion-title criterion) t)
                     (memq (chat-goal-criterion-status criterion)
                           chat-goal-criterion-statuses)
                     (chat-goal--bounded-text-list-p
                      (or (chat-goal-criterion-evidence criterion) nil)))
          (signal 'chat-goal-invalid '("invalid success criterion")))
        (when (gethash (chat-goal-criterion-id criterion) ids)
          (signal 'chat-goal-invalid '("duplicate success criterion")))
        (puthash (chat-goal-criterion-id criterion) t ids)
        (when (and (eq (chat-goal-criterion-status criterion) 'satisfied)
                   (null (chat-goal-criterion-evidence criterion)))
          (signal 'chat-goal-invalid '("satisfied criterion lacks evidence")))))
    (unless (seq-some #'chat-goal-criterion-required criteria)
      (signal 'chat-goal-invalid '("Goal requires one required criterion"))))
  (dolist (values (list (chat-goal-constraints goal)
                        (chat-goal-non-goals goal)
                        (chat-goal-sources goal)
                        (chat-goal-evidence goal)
                        (chat-goal-plan-ids goal)
                        (chat-goal-task-ids goal)))
    (unless (chat-goal--bounded-text-list-p (or values nil))
      (signal 'chat-goal-invalid '("Goal list field is invalid"))))
  (unless (and (chat-goal--bounded-text-p
                (chat-goal-current-checkpoint goal))
               (chat-goal--bounded-text-p (chat-goal-blocker-reason goal))
               (chat-goal--bounded-text-p (chat-goal-unblock-condition goal)))
    (signal 'chat-goal-invalid '("Goal state text is invalid")))
  (when (and (eq (chat-goal-status goal) 'blocked)
             (or (string-empty-p (or (chat-goal-blocker-reason goal) ""))
                 (string-empty-p (or (chat-goal-unblock-condition goal) ""))))
    (signal 'chat-goal-invalid '("blocked Goal requires reason and unblock condition")))
  (when (> (length (chat-goal-progress-log goal)) chat-goal-max-progress-entries)
    (signal 'chat-goal-invalid '("too many Goal progress entries")))
  goal)

(defun chat-goal--make-criteria (criteria)
  "Normalize decoded CRITERIA descriptions."
  (cl-loop for data in criteria
           for index from 1
           collect
           (chat-goal-criterion-create
            :id (or (chat-goal--get data 'id) (format "criterion-%d" index))
            :title (chat-goal--get data 'title)
            :required (chat-goal--bool (chat-goal--get data 'required) t)
            :status 'pending :evidence nil
            :metadata (chat-goal--get data 'metadata))))

(defun chat-goal--clone (goal)
  "Return a deep copy of GOAL."
  (chat-goal-from-alist (chat-goal-to-alist goal)))

(defun chat-goal--raw-session-goals (session)
  "Return decoded Goal records in SESSION without migration."
  (mapcar #'chat-goal-from-alist
          (chat-goal--list (chat-session-metadata-get session 'goalsV1))))

(defun chat-goal--save (session goals selected-id)
  "Persist GOALS and SELECTED-ID in SESSION."
  (setq goals
        (seq-take
         (sort goals (lambda (left right)
                       (> (or (chat-goal-updated-at left) 0)
                          (or (chat-goal-updated-at right) 0))))
         chat-goal-max-goals))
  (chat-session-metadata-set
   session 'goalsV1 (vconcat (mapcar #'chat-goal-to-alist goals)))
  (chat-session-metadata-set session 'selectedGoalId selected-id)
  (setf (chat-session-updated-at session) (current-time))
  (when (and (boundp 'chat-session-auto-save) chat-session-auto-save)
    (chat-session-save session))
  goals)

(defun chat-goal--legacy-work-state (session)
  "Return legacy work state from SESSION."
  (chat-session-metadata-get session 'work))

(defun chat-goal--migrate-legacy (session)
  "Migrate legacy title/status goals in SESSION exactly once."
  (unless (chat-session-metadata-get session 'goalMigrationVersion)
    (let* ((work (copy-tree (chat-goal--legacy-work-state session)))
           (legacy (chat-goal--list (chat-goal--get work 'goals)))
           (existing
            (mapcar (lambda (goal)
                      (if (chat-goal-p goal)
                          (chat-goal--clone goal)
                        (chat-goal-from-alist goal)))
                    (chat-goal--list (chat-goal--raw-session-goals session))))
           (selected (chat-session-metadata-get session 'selectedGoalId)))
      (chat-session-metadata-set session 'goalMigrationVersion 1)
      (when legacy
        (let ((now (chat-goal--now))
              migrated)
          (dolist (record legacy)
            (let* ((id (or (chat-goal--get record 'id)
                           (chat-session-new-message-id "legacy-goal")))
                   (title (or (chat-goal--get record 'title) "Legacy Goal"))
                   (old-status (or (chat-goal--get record 'status) "pending"))
                   (status (if (equal old-status "cancelled")
                               'cancelled 'paused)))
              (push
               (chat-goal-create-record
                :id id :revision 1 :session-id (chat-session-id session)
                :objective title
                :success-criteria
                (list (chat-goal-criterion-create
                       :id "legacy-contract" :title "Define verifiable success criteria"))
                :stopping-condition
                "User must define a verifiable stopping condition before resuming."
                :verification-spec '((predicate . "all-required-criteria"))
                :status status :created-at now :updated-at now
                :paused-at (and (eq status 'paused) now)
                :metadata `((legacy . t) (legacyStatus . ,old-status)))
               migrated)))
          (setq work (cons '(goals . [])
                           (assq-delete-all 'goals work)))
          (chat-session-metadata-set session 'work work)
          (setq migrated (nreverse migrated))
          ;; A versioned Goal contract is authoritative if a legacy record
          ;; happens to reuse its identifier.
          (setq migrated
                (seq-remove
                 (lambda (legacy-goal)
                   (seq-some
                    (lambda (goal)
                      (equal (chat-goal-id legacy-goal)
                             (chat-goal-id goal)))
                    existing))
                 migrated))
          (chat-goal--save
           session (append migrated existing)
           (or selected (and migrated (chat-goal-id (car migrated)))))))
      (when (and (null legacy)
                 (boundp 'chat-session-auto-save)
                 chat-session-auto-save)
        (chat-session-save session)))))

(defun chat-goal--session-goals (session)
  "Return all Goal records stored in SESSION, migrating legacy state."
  (chat-goal--migrate-legacy session)
  (chat-goal--raw-session-goals session))

(defun chat-goal--replace (session goal &optional selected-id)
  "Persist GOAL in SESSION and return it."
  (let* ((goals (chat-goal--session-goals session))
         (rest (cl-remove (chat-goal-id goal) goals
                          :key #'chat-goal-id :test #'equal)))
    (chat-goal--save session (cons goal rest)
                     (or selected-id
                         (chat-session-metadata-get session 'selectedGoalId)))
    goal))

(defun chat-goal--emit (type goal &optional extra)
  "Emit bounded TYPE facts for GOAL and EXTRA."
  (chat-event-emit
   type :session-id (chat-goal-session-id goal) :source 'goal :subject goal
   :payload
   (append
    `((goalId . ,(chat-goal-id goal))
      (revision . ,(chat-goal-revision goal))
      (status . ,(symbol-name (chat-goal-status goal)))
      (criterionCount . ,(length (chat-goal-success-criteria goal)))
      (evidenceCount . ,(length (chat-goal-evidence goal))))
    extra)))

(cl-defun chat-goal-create
    (session objective success-criteria stopping-condition
             &key constraints non-goals sources verification-spec project-root
             metadata)
  "Create, select and persist a Goal contract for SESSION."
  (when-let ((current (chat-goal-current session)))
    (unless (memq (chat-goal-status current) chat-goal-terminal-statuses)
      (signal 'chat-goal-transition-invalid '("a non-terminal Goal is selected"))))
  (let* ((now (chat-goal--now))
         (goal
          (chat-goal-create-record
           :id (chat-session-new-message-id "goal") :revision 1
           :session-id (chat-session-id session) :project-root project-root
           :objective objective
           :success-criteria (chat-goal--make-criteria success-criteria)
           :constraints (copy-sequence constraints)
           :non-goals (copy-sequence non-goals)
           :sources (copy-sequence sources)
           :stopping-condition stopping-condition
           :verification-spec
           (or verification-spec '((predicate . "all-required-criteria")))
           :status 'active :created-at now :updated-at now
           :progress-log nil :evidence nil :plan-ids nil :task-ids nil
           :metadata (copy-tree metadata))))
    (chat-goal--assert-project-scope session goal)
    (chat-goal-validate goal)
    (chat-goal--replace session goal (chat-goal-id goal))
    (chat-goal--emit 'goal-created goal)
    (chat-goal--emit 'goal-selected goal)
    goal))

(defun chat-goal-find (session goal-id)
  "Return GOAL-ID stored in SESSION."
  (seq-find (lambda (goal) (equal goal-id (chat-goal-id goal)))
            (chat-goal--session-goals session)))

(defun chat-goal-list (session)
  "Return SESSION Goal records newest first as copies."
  (mapcar #'chat-goal--clone (chat-goal--session-goals session)))

(defun chat-goal-current (session)
  "Return SESSION's selected Goal."
  (let ((goals (chat-goal--session-goals session)))
    (when-let ((id (chat-session-metadata-get session 'selectedGoalId)))
      (seq-find (lambda (goal) (equal id (chat-goal-id goal))) goals))))

(defun chat-goal-project-in-scope-p (session goal)
  "Return non-nil when GOAL belongs to SESSION's current project scope."
  (let ((goal-root (chat-goal-project-root goal))
        (session-root (chat-session-working-directory session)))
    (or (null goal-root)
        (and session-root
             (equal (file-name-as-directory
                     (chat-work-context--canonical-path goal-root))
                    (file-name-as-directory
                     (chat-work-context--canonical-path session-root)))))))

(defun chat-goal--assert-project-scope (session goal)
  "Signal when GOAL is outside SESSION's current project scope."
  (unless (chat-goal-project-in-scope-p session goal)
    (signal 'chat-goal-scope-mismatch nil))
  goal)

(defun chat-goal-select (session goal-id)
  "Select GOAL-ID in SESSION."
  (let ((goal (or (chat-goal-find session goal-id)
                  (signal 'chat-goal-invalid '("unknown Goal")))))
    (chat-goal--assert-project-scope session goal)
    (chat-goal--save session (chat-goal--session-goals session) goal-id)
    (chat-goal--emit 'goal-selected goal)
    goal))

(defun chat-goal--check-revision (goal expected)
  "Refuse GOAL when EXPECTED is stale."
  (unless (= expected (chat-goal-revision goal))
    (chat-goal--emit 'goal-conflicted goal)
    (signal 'chat-goal-stale-revision (list (chat-goal-revision goal)))))

(defun chat-goal--mutable-copy (session goal-id expected)
  "Return a mutable checked copy of GOAL-ID in SESSION."
  (let ((goal (chat-goal--clone
               (or (chat-goal-find session goal-id)
                   (signal 'chat-goal-invalid '("unknown Goal"))))))
    (chat-goal--assert-project-scope session goal)
    (chat-goal--check-revision goal expected)
    (when (memq (chat-goal-status goal) chat-goal-terminal-statuses)
      (signal 'chat-goal-transition-invalid '("terminal Goal cannot change")))
    goal))

(defun chat-goal--criterion (goal criterion-id)
  "Return CRITERION-ID in GOAL or signal."
  (or (seq-find (lambda (criterion)
                  (equal criterion-id (chat-goal-criterion-id criterion)))
                (chat-goal-success-criteria goal))
      (signal 'chat-goal-invalid '("unknown success criterion"))))

(defun chat-goal--evidence-known-p (session id)
  "Return non-nil when ID is known and session-scoped."
  (chat-work-plan-evidence-known-p session nil id))

(defun chat-goal--validate-evidence (session evidence)
  "Validate EVIDENCE for SESSION and return a de-duplicated copy."
  (unless (and evidence
               (<= (length evidence) chat-goal-max-links)
               (seq-every-p (lambda (id)
                              (chat-goal--evidence-known-p session id))
                            evidence))
    (signal 'chat-goal-evidence-invalid '("Goal evidence is unknown")))
  (delete-dups (copy-sequence evidence)))

(defun chat-goal--append-link (value values)
  "Return VALUES with VALUE appended once and bounded."
  (seq-take (delete-dups (append values (and value (list value))))
            chat-goal-max-links))

(cl-defun chat-goal-progress
    (session goal-id expected-revision
             &key checkpoint message criterion-id evidence plan-id task-id)
  "Record bounded progress against GOAL-ID at EXPECTED-REVISION."
  (let* ((goal (chat-goal--mutable-copy session goal-id expected-revision))
         (now (chat-goal--now))
         (known-evidence
          (and evidence (chat-goal--validate-evidence session evidence))))
    (unless (eq (chat-goal-status goal) 'active)
      (signal 'chat-goal-transition-invalid '("only active Goal can progress")))
    (unless (or checkpoint message criterion-id known-evidence plan-id task-id)
      (signal 'chat-goal-invalid '("empty Goal progress")))
    (when checkpoint
      (unless (chat-goal--bounded-text-p checkpoint t)
        (signal 'chat-goal-invalid '("invalid Goal checkpoint")))
      (setf (chat-goal-current-checkpoint goal) checkpoint))
    (when message
      (unless (chat-goal--bounded-text-p message t)
        (signal 'chat-goal-invalid '("invalid Goal progress message"))))
    (when criterion-id
      (let ((criterion (chat-goal--criterion goal criterion-id)))
        (unless known-evidence
          (signal 'chat-goal-evidence-invalid
                  '("criterion satisfaction requires evidence")))
        (setf (chat-goal-criterion-status criterion) 'satisfied
              (chat-goal-criterion-evidence criterion) known-evidence
              (chat-goal-criterion-satisfied-at criterion) now)))
    (setf (chat-goal-evidence goal)
          (seq-take (delete-dups
                     (append (chat-goal-evidence goal) known-evidence))
                    chat-goal-max-links)
          (chat-goal-plan-ids goal)
          (chat-goal--append-link plan-id (chat-goal-plan-ids goal))
          (chat-goal-active-plan-id goal)
          (or plan-id (chat-goal-active-plan-id goal))
          (chat-goal-task-ids goal)
          (chat-goal--append-link task-id (chat-goal-task-ids goal))
          (chat-goal-revision goal) (1+ expected-revision)
          (chat-goal-updated-at goal) now)
    (chat-goal--metadata-set goal 'needsAttention nil)
    (when (or checkpoint message criterion-id known-evidence plan-id task-id)
      (setf (chat-goal-progress-log goal)
            (seq-take
             (cons `((revision . ,(chat-goal-revision goal))
                     (at . ,now) (checkpoint . ,checkpoint)
                     (message . ,message) (criterionId . ,criterion-id)
                     (evidenceIds . ,(vconcat (or known-evidence nil)))
                     (planId . ,plan-id) (taskId . ,task-id))
                   (chat-goal-progress-log goal))
             chat-goal-max-progress-entries)))
    (chat-goal-validate goal)
    (chat-goal--replace session goal)
    (chat-goal--emit
     'goal-progressed goal
     `((criterionId . ,criterion-id)
       (hasCheckpoint . ,(and checkpoint t))
       (planId . ,plan-id) (taskId . ,task-id)))
    goal))

(defun chat-goal-mark-needs-attention (session reason)
  "Mark SESSION's active Goal as needing attention for bounded REASON."
  (when-let ((current (chat-goal-current session)))
    (when (and (eq (chat-goal-status current) 'active)
               (chat-goal-project-in-scope-p session current))
      (let ((goal (chat-goal--clone current))
            (now (chat-goal--now)))
        (unless (chat-goal--bounded-text-p reason t)
          (signal 'chat-goal-invalid '("invalid needs-attention reason")))
        (chat-goal--metadata-set goal 'needsAttention reason)
        (setf (chat-goal-revision goal) (1+ (chat-goal-revision current))
              (chat-goal-updated-at goal) now)
        (chat-goal--replace session goal)
        (chat-goal--emit 'goal-continuation-budget-exhausted goal)
        goal))))

(defun chat-goal-link-plan (session plan-id &optional message)
  "Link PLAN-ID to SESSION's active Goal, if any."
  (when-let ((goal (chat-goal-current session)))
    (when (and (eq (chat-goal-status goal) 'active)
               (chat-goal-project-in-scope-p session goal))
      (chat-goal-progress
       session (chat-goal-id goal) (chat-goal-revision goal)
       :message (or message "A work plan was linked to this Goal.")
       :plan-id plan-id))))

(defun chat-goal-link-task (session task-id)
  "Link TASK-ID to SESSION's active Goal, if any."
  (when-let ((goal (chat-goal-current session)))
    (when (and (eq (chat-goal-status goal) 'active)
               (chat-goal-project-in-scope-p session goal))
      (chat-goal-progress
       session (chat-goal-id goal) (chat-goal-revision goal)
       :message "A runtime task was linked to this Goal." :task-id task-id))))

(defun chat-goal-pause (session goal-id expected-revision)
  "Pause GOAL-ID at EXPECTED-REVISION."
  (let* ((goal (chat-goal--mutable-copy session goal-id expected-revision))
         (now (chat-goal--now)))
    (unless (memq (chat-goal-status goal) '(active blocked))
      (signal 'chat-goal-transition-invalid '("Goal cannot be paused")))
    (setf (chat-goal-status goal) 'paused
          (chat-goal-paused-at goal) now
          (chat-goal-revision goal) (1+ expected-revision)
          (chat-goal-updated-at goal) now)
    (chat-goal--replace session goal)
    (chat-goal--emit 'goal-paused goal)
    goal))

(defun chat-goal-resume (session goal-id expected-revision)
  "Resume paused or blocked GOAL-ID at EXPECTED-REVISION."
  (let* ((goal (chat-goal--mutable-copy session goal-id expected-revision))
         (old-status (chat-goal-status goal))
         (now (chat-goal--now)))
    (unless (memq old-status '(paused blocked))
      (signal 'chat-goal-transition-invalid '("Goal is not paused or blocked")))
    (when (chat-goal--get (chat-goal-metadata goal) 'legacy)
      (signal 'chat-goal-transition-invalid
              '("legacy Goal needs a new explicit completion contract")))
    (setf (chat-goal-status goal) 'active
          (chat-goal-blocker-reason goal) nil
          (chat-goal-unblock-condition goal) nil
          (chat-goal-revision goal) (1+ expected-revision)
          (chat-goal-updated-at goal) now)
    (chat-goal--replace session goal)
    (chat-goal--emit (if (eq old-status 'blocked)
                         'goal-unblocked 'goal-resumed)
                     goal)
    goal))

(defun chat-goal-block
    (session goal-id expected-revision reason unblock-condition)
  "Block GOAL-ID with REASON and UNBLOCK-CONDITION."
  (let* ((goal (chat-goal--mutable-copy session goal-id expected-revision))
         (now (chat-goal--now)))
    (unless (eq (chat-goal-status goal) 'active)
      (signal 'chat-goal-transition-invalid '("only active Goal can block")))
    (unless (and (chat-goal--bounded-text-p reason t)
                 (chat-goal--bounded-text-p unblock-condition t))
      (signal 'chat-goal-invalid '("block reason and condition are required")))
    (setf (chat-goal-status goal) 'blocked
          (chat-goal-blocker-reason goal) reason
          (chat-goal-unblock-condition goal) unblock-condition
          (chat-goal-blocked-at goal) now
          (chat-goal-revision goal) (1+ expected-revision)
          (chat-goal-updated-at goal) now)
    (chat-goal-validate goal)
    (chat-goal--replace session goal)
    (chat-goal--emit 'goal-blocked goal '((hasReason . t) (hasCondition . t)))
    goal))

(defun chat-goal-completion-ready-p (session goal)
  "Return non-nil when GOAL deterministically satisfies its contract."
  (and (chat-goal-project-in-scope-p session goal)
       (eq (chat-goal--verification-predicate goal) 'all-required-criteria)
       (seq-every-p
        (lambda (criterion)
          (or (not (chat-goal-criterion-required criterion))
              (and (eq (chat-goal-criterion-status criterion) 'satisfied)
                   (chat-goal-criterion-evidence criterion)
                   (seq-every-p
                    (lambda (id) (chat-goal--evidence-known-p session id))
                    (chat-goal-criterion-evidence criterion)))))
        (chat-goal-success-criteria goal))))

(defun chat-goal-complete (session goal-id expected-revision)
  "Complete GOAL-ID only when deterministic evidence satisfies it."
  (let* ((goal (chat-goal--mutable-copy session goal-id expected-revision))
         (now (chat-goal--now)))
    (unless (eq (chat-goal-status goal) 'active)
      (signal 'chat-goal-transition-invalid '("only active Goal can complete")))
    (unless (chat-goal-completion-ready-p session goal)
      (chat-goal--emit 'goal-completion-refused goal)
      (signal 'chat-goal-evidence-invalid
              '("Goal stopping condition is not verified")))
    (setf (chat-goal-status goal) 'completed
          (chat-goal-completed-at goal) now
          (chat-goal-revision goal) (1+ expected-revision)
          (chat-goal-updated-at goal) now)
    (chat-goal--replace session goal)
    (chat-goal--emit 'goal-completed goal)
    goal))

(defun chat-goal-cancel (session goal-id expected-revision)
  "Cancel GOAL-ID at EXPECTED-REVISION."
  (let* ((goal (chat-goal--mutable-copy session goal-id expected-revision))
         (now (chat-goal--now)))
    (setf (chat-goal-status goal) 'cancelled
          (chat-goal-revision goal) (1+ expected-revision)
          (chat-goal-updated-at goal) now)
    (chat-goal--replace session goal)
    (chat-goal--emit 'goal-cancelled goal)
    goal))

(defun chat-goal-clear (session)
  "Clear SESSION's selected Goal without deleting history."
  (let ((goal (chat-goal-current session)))
    (chat-goal--save session (chat-goal--session-goals session) nil)
    (when goal (chat-goal--emit 'goal-cleared goal))
    goal))

(defun chat-goal-remaining-criteria (goal)
  "Return required unsatisfied criteria in GOAL."
  (seq-filter
   (lambda (criterion)
     (and (chat-goal-criterion-required criterion)
          (not (eq (chat-goal-criterion-status criterion) 'satisfied))))
   (chat-goal-success-criteria goal)))

(defun chat-goal-context-fragment (session &optional since-revision)
  "Return SESSION's selected Goal as one protected context fragment."
  (when-let* ((goal (chat-goal-current session))
              ((memq (chat-goal-status goal) '(active paused blocked))))
    (if (not (chat-goal-project-in-scope-p session goal))
        (chat-context-fragment-create
         :id (format "goal-scope-mismatch:%s:%d"
                     (chat-goal-id goal) (chat-goal-revision goal))
         :kind 'objective :authority 'runtime :source-kind 'goal
         :source-id (chat-goal-id goal) :scope 'session
         :scope-id (chat-session-id session)
         :priority 100 :residency 'protected :budget-policy 'preserve
         :payload "A selected Goal belongs to another project scope. Do not read, advance, resume, or complete it in this project."
         :status 'active
         :metadata `((revision . ,(chat-goal-revision goal))
                     (scopeMismatch . t)))
      (let* ((remaining (chat-goal-remaining-criteria goal))
           (recent-evidence
            (if since-revision
                (delete-dups
                 (apply
                  #'append
                  (mapcar
                   (lambda (entry)
                     (and (> (or (chat-goal--get entry 'revision) 0)
                             since-revision)
                          (chat-goal--list
                           (chat-goal--get entry 'evidenceIds))))
                   (chat-goal-progress-log goal))))
              (seq-take (reverse (chat-goal-evidence goal)) 5)))
           (payload
            (string-join
             (delq
              nil
              (list
               (format "Goal %s revision %d [%s]: %s"
                       (chat-goal-id goal) (chat-goal-revision goal)
                       (chat-goal-status goal) (chat-goal-objective goal))
               (format "Stopping condition: %s"
                       (chat-goal-stopping-condition goal))
               (and (chat-goal-current-checkpoint goal)
                    (format "Current checkpoint: %s"
                            (chat-goal-current-checkpoint goal)))
               (and remaining
                    (format "Remaining required criteria: %s"
                            (mapconcat #'chat-goal-criterion-title
                                       (seq-take remaining 8) "; ")))
               (and recent-evidence
                    (format "Verified evidence: %s"
                            (mapconcat #'identity recent-evidence "; ")))
               (and (eq (chat-goal-status goal) 'blocked)
                    (format "Blocker: %s\nUnblock condition: %s"
                            (chat-goal-blocker-reason goal)
                            (chat-goal-unblock-condition goal)))
               (and (eq (chat-goal-status goal) 'paused)
                    "The user paused this Goal. Do not advance or resume it.")
               (when-let ((attention
                           (chat-goal--get (chat-goal-metadata goal)
                                           'needsAttention)))
                 (format "Needs attention: %s" attention))))
             "\n")))
      (chat-context-fragment-create
       :id (format "goal-fragment:%s:%d"
                   (chat-goal-id goal) (chat-goal-revision goal))
       :kind 'objective :authority 'runtime :source-kind 'goal
       :source-id (chat-goal-id goal) :scope 'session
       :scope-id (chat-session-id session)
       :priority 100 :residency 'protected :budget-policy 'preserve
       :payload (truncate-string-to-width
                 payload chat-goal-max-projection-chars nil nil t)
       :status 'active
       :metadata `((revision . ,(chat-goal-revision goal))
                   (goalStatus . ,(symbol-name (chat-goal-status goal)))))))))

(defun chat-goal-ui-projection (session)
  "Return stable UI projection for SESSION's selected Goal."
  (when-let ((goal (chat-goal-current session)))
    (let* ((in-scope (chat-goal-project-in-scope-p session goal))
           (criteria (and in-scope (chat-goal-success-criteria goal)))
           (satisfied (seq-count
                       (lambda (criterion)
                         (eq (chat-goal-criterion-status criterion) 'satisfied))
                       criteria)))
      (list :id (chat-goal-id goal) :revision (chat-goal-revision goal)
            :status (chat-goal-status goal)
            :scope-mismatch (not in-scope)
            :objective (if in-scope (chat-goal-objective goal)
                         "Goal is outside the current project scope")
            :stopping-condition (and in-scope
                                     (chat-goal-stopping-condition goal))
            :checkpoint (and in-scope (chat-goal-current-checkpoint goal))
            :blocker-reason (and in-scope (chat-goal-blocker-reason goal))
            :unblock-condition (and in-scope
                                    (chat-goal-unblock-condition goal))
            :needs-attention
            (and in-scope
                 (chat-goal--get (chat-goal-metadata goal) 'needsAttention))
            :satisfied satisfied :total (length criteria)
            :remaining (and in-scope
                            (mapcar #'chat-goal-criterion-title
                                    (chat-goal-remaining-criteria goal)))
            :active-plan-id (and in-scope
                                 (chat-goal-active-plan-id goal))))))

(provide 'chat-goal)
;;; chat-goal.el ends here
