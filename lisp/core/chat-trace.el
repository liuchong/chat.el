;;; chat-trace.el --- Derived runtime traces -*- lexical-binding: t; -*-

;;; Commentary:

;; A trace is reconstructed from the versioned session wire.  It is a
;; bounded projection of identifiers, timings and counts, never another
;; transcript or event database.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'chat-session-wire)

(defconst chat-trace-schema-version 1
  "Current derived trace schema.")

(defcustom chat-trace-max-export-items 500
  "Maximum Turn and task rows included in one Trace export."
  :type 'integer
  :group 'chat)

(defconst chat-trace--token-keys
  '(input_tokens output_tokens total_tokens
    cache_read_tokens cache_write_tokens)
  "Token counters projected from model usage events.")

(defconst chat-trace--known-kinds
  '("wire-archived"
    "agent-start" "agent-end" "profile-resolved" "context-transformed"
    "turn-start" "turn-ended" "turn-failed"
    "stream-chunk" "stream-reasoning" "stream-result"
    "model-tool-call-delta" "model-usage"
    "tool-batch-start" "tool-event" "tool-batch-end"
    "message-appended" "truncated" "response" "followup" "steering"
    "prepared-next-turn" "error"
    "session-created" "session-resumed" "session-branched"
    "user-prompt-submitted" "assistant-message-appended"
    "pre-tool" "post-tool" "permission-requested" "permission-resolved"
    "approval-guard-review"
    "task-started" "task-updated" "task-ended"
    "subagent-started" "subagent-ended"
    "pre-compact" "compaction" "post-compact"
    "checkpoint-created" "checkpoint-file-captured" "checkpoint-updated"
    "checkpoint-rolled-back"
    "workspace-created" "workspace-reconciled" "workspace-release-refused"
    "workspace-released"
    "execution-started" "execution-ended" "execution-interrupted"
    "execution-retry-refused"
    "attachment-added" "artifact-created")
  "Event kinds understood by Trace schema version 1.")

(defconst chat-trace--first-output-kinds
  '("stream-chunk" "stream-reasoning" "stream-result"
    "model-tool-call-delta" "response" "turn-ended" "turn-failed")
  "Kinds that close first-output latency for a Turn.")

(cl-defstruct (chat-trace-turn
               (:constructor chat-trace-turn-create-record))
  "One derived Turn trace."
  schema-version id first-seq last-seq started-at ended-at status reason
  first-output-ms duration-ms tokens counts task-ids record-count)

(cl-defstruct (chat-trace-task
               (:constructor chat-trace-task-create-record))
  "One derived task node."
  schema-version id parent-id kind status first-seq last-seq
  started-at ended-at children event-count)

(cl-defstruct (chat-trace
               (:constructor chat-trace-create-record))
  "One reconstructed session trace."
  schema-version session-id first-seq last-seq started-at ended-at status reason
  first-output-ms duration-ms tokens counts turns tasks diagnostics record-count)

(defun chat-trace--number (value)
  "Return VALUE when numeric, otherwise zero."
  (if (numberp value) value 0))

(defun chat-trace--increment (alist key &optional amount)
  "Increment KEY in ALIST by AMOUNT and return ALIST."
  (let ((cell (assq key alist)))
    (if cell
        (setcdr cell (+ (cdr cell) (or amount 1)))
      (push (cons key (or amount 1)) alist))
    alist))

(defun chat-trace--empty-tokens ()
  "Return zeroed token counters."
  (mapcar (lambda (key) (cons key 0)) chat-trace--token-keys))

(defun chat-trace--tokens-add-record (tokens record)
  "Add model usage from RECORD into TOKENS and return TOKENS."
  (when (equal (alist-get 'kind record) "model-usage")
    (let ((payload (alist-get 'payload record)))
      (dolist (key chat-trace--token-keys)
        (let ((cell (assq key tokens)))
          (setcdr cell (+ (cdr cell)
                          (chat-trace--number (alist-get key payload))))))))
  tokens)

(defun chat-trace--counts-add-record (counts record)
  "Add RECORD's bounded measurements to COUNTS and return COUNTS."
  (let ((kind (alist-get 'kind record))
        (payload (alist-get 'payload record)))
    (pcase kind
      ("turn-start"
       (setq counts (chat-trace--increment counts 'model_rounds)))
      ("stream-chunk"
       (setq counts (chat-trace--increment counts 'text_events)))
      ("stream-reasoning"
       (setq counts (chat-trace--increment counts 'reasoning_events)))
      ("model-tool-call-delta"
       (setq counts (chat-trace--increment counts 'tool_call_deltas)))
      ("tool-batch-start"
       (setq counts (chat-trace--increment counts 'tool_batches)
             counts (chat-trace--increment
                     counts 'tools
                     (chat-trace--number (alist-get 'count payload)))))
      ("tool-event"
       (setq counts (chat-trace--increment counts 'tool_events)))
      ("permission-requested"
       (setq counts (chat-trace--increment counts 'approvals)))
      ("approval-guard-review"
       (setq counts (chat-trace--increment counts 'guard_reviews)))
      ("task-started"
       (setq counts (chat-trace--increment counts 'tasks)))
      ("subagent-started"
       (setq counts (chat-trace--increment counts 'subagents)))
      ("compaction"
       (setq counts (chat-trace--increment counts 'compactions)))
      ("checkpoint-created"
       (setq counts (chat-trace--increment counts 'checkpoints)))
      ("execution-started"
       (setq counts (chat-trace--increment counts 'executions)))
      ((or "attachment-added" "artifact-created")
       (setq counts (chat-trace--increment counts 'artifacts))))
    counts))

(defun chat-trace--terminal-status (records)
  "Return terminal status and reason derived from RECORDS."
  (let (status reason)
    (dolist (record records)
      (let ((kind (alist-get 'kind record))
            (payload (alist-get 'payload record)))
        (cond
         ((equal kind "turn-failed")
          (setq status 'failed
                reason (alist-get 'reason payload)))
         ((equal kind "turn-ended")
          (setq status
                (or (let ((value (alist-get 'status payload)))
                      (and value (intern value)))
                    'completed)
                reason (alist-get 'reason payload)))
         ((equal kind "agent-end")
          (setq status
                (or (let ((value (alist-get 'status payload)))
                      (and value (intern value)))
                    status)
                reason (or (alist-get 'reason payload) reason))))))
    (cons (or status 'interrupted) reason)))

(defun chat-trace--scope-fields (records)
  "Return common timing, token and count fields for RECORDS."
  (let ((first-seq nil) (last-seq nil)
        (started-at nil) (ended-at nil) (first-output-at nil)
        (tokens (chat-trace--empty-tokens))
        (counts nil))
    (dolist (record records)
      (let ((seq (alist-get 'seq record))
            (stamp (alist-get 'timestamp_ms record))
            (kind (alist-get 'kind record)))
        (when (numberp seq)
          (setq first-seq (or first-seq seq)
                last-seq seq))
        (when (numberp stamp)
          (setq started-at (or started-at stamp)
                ended-at stamp)
          (when (and (null first-output-at)
                     (member kind chat-trace--first-output-kinds))
            (setq first-output-at stamp)))
        (chat-trace--tokens-add-record tokens record)
        (setq counts (chat-trace--counts-add-record counts record))))
    (let ((terminal (chat-trace--terminal-status records)))
      (list :first-seq first-seq :last-seq last-seq
            :started-at started-at :ended-at ended-at
            :status (car terminal) :reason (cdr terminal)
            :first-output-ms
            (and started-at first-output-at
                 (max 0 (- first-output-at started-at)))
            :duration-ms
            (and started-at ended-at (max 0 (- ended-at started-at)))
            :tokens tokens :counts (nreverse counts)
            :record-count (length records)))))

(defun chat-trace--build-turn (turn-id records)
  "Build one Turn trace for TURN-ID from RECORDS."
  (let* ((fields (chat-trace--scope-fields records))
         (task-ids
          (delete-dups
           (delq nil (mapcar (lambda (record)
                               (alist-get 'task_id record))
                             records)))))
    (chat-trace-turn-create-record
     :schema-version chat-trace-schema-version :id turn-id
     :first-seq (plist-get fields :first-seq)
     :last-seq (plist-get fields :last-seq)
     :started-at (plist-get fields :started-at)
     :ended-at (plist-get fields :ended-at)
     :status (plist-get fields :status)
     :reason (plist-get fields :reason)
     :first-output-ms (plist-get fields :first-output-ms)
     :duration-ms (plist-get fields :duration-ms)
     :tokens (plist-get fields :tokens)
     :counts (plist-get fields :counts)
     :task-ids task-ids
     :record-count (plist-get fields :record-count))))

(defun chat-trace--task-event-p (record)
  "Return non-nil when RECORD contributes to a task node."
  (member (alist-get 'kind record)
          '("task-started" "task-updated" "task-ended"
            "subagent-started" "subagent-ended")))

(defun chat-trace--build-tasks (records)
  "Return task nodes and missing-parent count from RECORDS."
  (let ((table (make-hash-table :test 'equal))
        order)
    (dolist (record records)
      (when (chat-trace--task-event-p record)
        (let* ((id (alist-get 'task_id record))
               (payload (alist-get 'payload record))
               (kind-name (alist-get 'kind record))
               (node (and id (gethash id table))))
          (when id
            (unless node
              (setq node
                    (chat-trace-task-create-record
                     :schema-version chat-trace-schema-version
                     :id id
                     :parent-id (alist-get 'parent_id record)
                     :kind (or (and (alist-get 'kind payload)
                                    (intern (alist-get 'kind payload)))
                               (and (string-prefix-p "subagent-" kind-name)
                                    'subagent)
                               'task)
                     :status 'unknown
                     :first-seq (alist-get 'seq record)
                     :started-at (alist-get 'timestamp_ms record)
                     :children nil :event-count 0))
              (puthash id node table)
              (push id order))
            (when (and (null (chat-trace-task-parent-id node))
                       (alist-get 'parent_id record))
              (setf (chat-trace-task-parent-id node)
                    (alist-get 'parent_id record)))
            (when-let* ((status (alist-get 'status payload)))
              (setf (chat-trace-task-status node) (intern status)))
            (setf (chat-trace-task-last-seq node) (alist-get 'seq record)
                  (chat-trace-task-ended-at node)
                  (alist-get 'timestamp_ms record)
                  (chat-trace-task-event-count node)
                  (1+ (chat-trace-task-event-count node)))))))
    (maphash
     (lambda (_id node)
       (when-let* ((parent-id (chat-trace-task-parent-id node))
                   (parent (gethash parent-id table)))
         (setf (chat-trace-task-children parent)
               (append (chat-trace-task-children parent)
                       (list (chat-trace-task-id node))))))
     table)
    (let ((nodes
           (mapcar (lambda (id) (gethash id table)) (nreverse order)))
          (missing 0))
      (dolist (node nodes)
        (when (and (chat-trace-task-parent-id node)
                   (null (gethash (chat-trace-task-parent-id node) table)))
          (setq missing (1+ missing))))
      (cons nodes missing))))

(defun chat-trace--deduplicate (records)
  "Return RECORDS without repeated numeric sequences and diagnostics."
  (let ((seen (make-hash-table :test 'eql))
        (unique nil) (duplicates 0) (invalid 0)
        (previous nil) (missing 0))
    (dolist (record records)
      (let ((seq (alist-get 'seq record)))
        (cond
         ((not (numberp seq))
          (setq invalid (1+ invalid))
          (push record unique))
         ((gethash seq seen)
          (setq duplicates (1+ duplicates)))
         (t
          (puthash seq t seen)
          (when previous
            (setq missing (+ missing (max 0 (1- (- seq previous))))))
          (setq previous seq)
          (push record unique)))))
    (cons (nreverse unique)
          `((duplicate_sequences . ,duplicates)
            (missing_sequences . ,missing)
            (invalid_sequences . ,invalid)))))

(defun chat-trace-reconstruct (session-id)
  "Reconstruct and return the complete Trace for SESSION-ID."
  (let* ((deduplicated
          (chat-trace--deduplicate
           (chat-session-wire-read-all session-id)))
         (records (car deduplicated))
         (diagnostics (cdr deduplicated))
         (turn-table (make-hash-table :test 'equal))
         turn-order
         (unknown 0))
    (dolist (record records)
      (let ((turn-id (alist-get 'turn_id record))
            (kind (alist-get 'kind record)))
        (unless (member kind chat-trace--known-kinds)
          (setq unknown (1+ unknown)))
        (when turn-id
          (unless (gethash turn-id turn-table)
            (push turn-id turn-order))
          (puthash turn-id
                   (cons record (gethash turn-id turn-table))
                   turn-table))))
    (let* ((turns
            (mapcar
             (lambda (turn-id)
               (chat-trace--build-turn
                turn-id (nreverse (gethash turn-id turn-table))))
             (nreverse turn-order)))
           (tasks-and-missing (chat-trace--build-tasks records))
           (fields (chat-trace--scope-fields records))
           (diagnostics
            (append diagnostics
                    `((unknown_kinds . ,unknown)
                      (missing_parents . ,(cdr tasks-and-missing))))))
      (chat-trace-create-record
       :schema-version chat-trace-schema-version
       :session-id session-id
       :first-seq (plist-get fields :first-seq)
       :last-seq (plist-get fields :last-seq)
       :started-at (plist-get fields :started-at)
       :ended-at (plist-get fields :ended-at)
       :status (plist-get fields :status)
       :reason (plist-get fields :reason)
       :first-output-ms (and turns
                             (chat-trace-turn-first-output-ms (car turns)))
       :duration-ms (plist-get fields :duration-ms)
       :tokens (plist-get fields :tokens)
       :counts (plist-get fields :counts)
       :turns turns
       :tasks (car tasks-and-missing)
       :diagnostics diagnostics
       :record-count (plist-get fields :record-count)))))

(defun chat-trace--tokens-json (tokens)
  "Return stable JSON-friendly TOKEN counters."
  (mapcar (lambda (key) (cons key (or (alist-get key tokens) 0)))
          chat-trace--token-keys))

(defun chat-trace--turn-to-json (turn)
  "Return a bounded JSON projection of TURN."
  `((schemaVersion . ,(chat-trace-turn-schema-version turn))
    (turnId . ,(chat-trace-turn-id turn))
    (firstSeq . ,(chat-trace-turn-first-seq turn))
    (lastSeq . ,(chat-trace-turn-last-seq turn))
    (startedAt . ,(chat-trace-turn-started-at turn))
    (endedAt . ,(chat-trace-turn-ended-at turn))
    (status . ,(symbol-name (chat-trace-turn-status turn)))
    (reason . ,(chat-trace-turn-reason turn))
    (firstOutputMs . ,(chat-trace-turn-first-output-ms turn))
    (durationMs . ,(chat-trace-turn-duration-ms turn))
    (tokens . ,(chat-trace--tokens-json (chat-trace-turn-tokens turn)))
    (counts . ,(chat-trace-turn-counts turn))
    (taskIds . ,(chat-trace-turn-task-ids turn))
    (recordCount . ,(chat-trace-turn-record-count turn))))

(defun chat-trace--task-to-json (task)
  "Return a bounded JSON projection of TASK."
  `((schemaVersion . ,(chat-trace-task-schema-version task))
    (taskId . ,(chat-trace-task-id task))
    (parentId . ,(chat-trace-task-parent-id task))
    (kind . ,(symbol-name (chat-trace-task-kind task)))
    (status . ,(symbol-name (chat-trace-task-status task)))
    (firstSeq . ,(chat-trace-task-first-seq task))
    (lastSeq . ,(chat-trace-task-last-seq task))
    (startedAt . ,(chat-trace-task-started-at task))
    (endedAt . ,(chat-trace-task-ended-at task))
    (children . ,(chat-trace-task-children task))
    (eventCount . ,(chat-trace-task-event-count task))))

(defun chat-trace-to-json-data (trace)
  "Return a bounded JSON-friendly projection of TRACE."
  (let* ((turns (chat-trace-turns trace))
         (tasks (chat-trace-tasks trace))
         (kept-turns (seq-take turns chat-trace-max-export-items))
         (kept-tasks (seq-take tasks chat-trace-max-export-items)))
    `((schemaVersion . ,(chat-trace-schema-version trace))
      (sessionId . ,(chat-trace-session-id trace))
      (firstSeq . ,(chat-trace-first-seq trace))
      (lastSeq . ,(chat-trace-last-seq trace))
      (startedAt . ,(chat-trace-started-at trace))
      (endedAt . ,(chat-trace-ended-at trace))
      (status . ,(symbol-name (chat-trace-status trace)))
      (reason . ,(chat-trace-reason trace))
      (firstOutputMs . ,(chat-trace-first-output-ms trace))
      (durationMs . ,(chat-trace-duration-ms trace))
      (tokens . ,(chat-trace--tokens-json (chat-trace-tokens trace)))
      (counts . ,(chat-trace-counts trace))
      (turns . ,(mapcar #'chat-trace--turn-to-json kept-turns))
      (tasks . ,(mapcar #'chat-trace--task-to-json kept-tasks))
      (diagnostics . ,(chat-trace-diagnostics trace))
      (recordCount . ,(chat-trace-record-count trace))
      (truncatedTurns . ,(- (length turns) (length kept-turns)))
      (truncatedTasks . ,(- (length tasks) (length kept-tasks))))))

(defun chat-trace-export-json (trace)
  "Return bounded JSON text for TRACE."
  (json-encode (chat-trace-to-json-data trace)))

(defun chat-trace--counter-deltas (left right keys)
  "Return RIGHT minus LEFT for counter KEYS."
  (mapcar
   (lambda (key)
     (cons key (- (chat-trace--number (alist-get key right))
                  (chat-trace--number (alist-get key left)))))
   keys))

(defun chat-trace-compare (left right)
  "Return bounded metric deltas from Trace LEFT to RIGHT."
  `((schemaVersion . ,chat-trace-schema-version)
    (leftSessionId . ,(chat-trace-session-id left))
    (rightSessionId . ,(chat-trace-session-id right))
    (statusChanged
     . ,(not (eq (chat-trace-status left) (chat-trace-status right))))
    (durationDeltaMs
     . ,(- (chat-trace--number (chat-trace-duration-ms right))
           (chat-trace--number (chat-trace-duration-ms left))))
    (firstOutputDeltaMs
     . ,(- (chat-trace--number (chat-trace-first-output-ms right))
           (chat-trace--number (chat-trace-first-output-ms left))))
    (tokens
     . ,(chat-trace--counter-deltas
         (chat-trace-tokens left) (chat-trace-tokens right)
         chat-trace--token-keys))
    (counts
     . ,(chat-trace--counter-deltas
         (chat-trace-counts left) (chat-trace-counts right)
         (delete-dups
          (append (mapcar #'car (chat-trace-counts left))
                  (mapcar #'car (chat-trace-counts right))))))))

(provide 'chat-trace)
;;; chat-trace.el ends here
