;;; chat-checkpoint.el --- Owned file and conversation recovery -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;;; Commentary:

;; A checkpoint exists before a user Turn.  Direct file targets are captured
;; lazily, but always before their first write.  Rollback restores only those
;; owned paths and refuses when the same path changed outside the runtime.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'chat-event)
(require 'chat-session)

(declare-function chat-code-session-project-root "chat-code" (session))
(declare-function chat-files--tool-target-paths "chat-files" (tool-id arguments))
(declare-function chat-transcript-turn "chat-transcript" (message))

(defgroup chat-checkpoint nil
  "Checkpointed recovery for runtime-owned changes."
  :group 'chat)

(defconst chat-checkpoint-schema-version 1
  "Current checkpoint and file entry schema version.")

(defcustom chat-checkpoint-directory
  (expand-file-name "checkpoints/" (expand-file-name "~/.chat/"))
  "Directory containing durable checkpoint records and file snapshots."
  :type 'directory
  :group 'chat-checkpoint)

(defcustom chat-checkpoint-auto-save t
  "When non-nil, persist a checkpoint after every state transition."
  :type 'boolean
  :group 'chat-checkpoint)

(define-error 'chat-checkpoint-invalid "Invalid checkpoint")
(define-error 'chat-checkpoint-workspace-mismatch
  "Checkpoint belongs to another workspace")
(define-error 'chat-checkpoint-external-drift
  "Runtime-owned files changed outside the checkpoint")

(cl-defstruct
    (chat-checkpoint-file
     (:constructor chat-checkpoint-file-create
                   (&key (schema-version chat-checkpoint-schema-version)
                         path status original-kind original-digest
                         original-mode original-link snapshot
                         post-kind post-digest captured-at updated-at)))
  "One path captured and optionally owned by a checkpoint."
  schema-version path status original-kind original-digest original-mode
  original-link snapshot post-kind post-digest captured-at updated-at)

(cl-defstruct
    (chat-checkpoint
     (:constructor chat-checkpoint-create-record
                   (&key (schema-version chat-checkpoint-schema-version)
                         id session-id turn-id reason (status 'active)
                         created-at updated-at conversation-head-id
                         workspace-kind workspace-root git-head git-status
                         files boundaries limitations rollbacks metadata)))
  "One durable recovery point."
  schema-version id session-id turn-id reason status created-at updated-at
  conversation-head-id workspace-kind workspace-root git-head git-status
  files boundaries limitations rollbacks metadata)

(defvar chat-checkpoint--registry (make-hash-table :test 'equal)
  "Loaded checkpoints by stable ID.")

(defvar chat-checkpoint--id-sequence 0
  "Process-local suffix for checkpoint IDs created in one millisecond.")

(defun chat-checkpoint--timestamp-ms ()
  "Return the current Unix time in milliseconds."
  (round (* 1000 (float-time))))

(defun chat-checkpoint-new-id ()
  "Return a fresh checkpoint ID."
  (format "checkpoint-%d-%d"
          (chat-checkpoint--timestamp-ms)
          (cl-incf chat-checkpoint--id-sequence)))

(defun chat-checkpoint--symbol (value &optional fallback)
  "Return VALUE as a symbol, or FALLBACK."
  (cond ((symbolp value) value)
        ((and (stringp value) (not (string-empty-p value))) (intern value))
        (t fallback)))

(defun chat-checkpoint--safe-id-p (value)
  "Return non-nil when VALUE is safe as one directory component."
  (and (stringp value)
       (string-match-p "\\`[[:alnum:]_.-]+\\'" value)))

(defun chat-checkpoint--checkpoint-directory (session-id checkpoint-id)
  "Return directory for SESSION-ID and CHECKPOINT-ID."
  (unless (and (chat-checkpoint--safe-id-p session-id)
               (chat-checkpoint--safe-id-p checkpoint-id))
    (signal 'chat-checkpoint-invalid
            (list "unsafe checkpoint identity" session-id checkpoint-id)))
  (expand-file-name
   (concat checkpoint-id "/")
   (expand-file-name (concat session-id "/") chat-checkpoint-directory)))

(defun chat-checkpoint--record-file (checkpoint)
  "Return CHECKPOINT's JSON record path."
  (expand-file-name
   "checkpoint.json"
   (chat-checkpoint--checkpoint-directory
    (chat-checkpoint-session-id checkpoint)
    (chat-checkpoint-id checkpoint))))

(defun chat-checkpoint--snapshot-directory (checkpoint)
  "Return CHECKPOINT's file snapshot directory."
  (expand-file-name
   "files/"
   (chat-checkpoint--checkpoint-directory
    (chat-checkpoint-session-id checkpoint)
    (chat-checkpoint-id checkpoint))))

(defun chat-checkpoint--workspace-root (session)
  "Return the canonical workspace root for SESSION, or nil."
  (let ((root
         (or (chat-session-working-directory session)
             (and (fboundp 'chat-code-session-project-root)
                  (chat-code-session-project-root session)))))
    (when (and root (file-directory-p root))
      (file-name-as-directory (file-truename root)))))

(defun chat-checkpoint--workspace-kind (session)
  "Return SESSION's recorded workspace kind."
  (let* ((data (chat-session-metadata-get session 'workspace))
         (kind (and (listp data)
                    (or (alist-get 'kind data)
                        (plist-get data :kind)))))
    (chat-checkpoint--symbol kind 'checkout)))

(defun chat-checkpoint--git-output (root &rest args)
  "Return trimmed Git output for ROOT and ARGS, or nil on failure."
  (when root
    (with-temp-buffer
      (let ((default-directory root))
        (when (zerop (apply #'process-file "git" nil t nil
                            "-C" root args))
          (string-trim-right (buffer-string)))))))

(defun chat-checkpoint--git-observation (root)
  "Return Git HEAD and porcelain status observed at ROOT."
  (when (chat-checkpoint--git-output root "rev-parse" "--show-toplevel")
    (list
     (chat-checkpoint--git-output root "rev-parse" "--verify" "HEAD")
     (chat-checkpoint--git-output
      root "status" "--porcelain=v1" "--untracked-files=all"))))

(defun chat-checkpoint--file-digest (file)
  "Return SHA-256 digest for regular FILE bytes."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (secure-hash 'sha256 (current-buffer))))

(defun chat-checkpoint--path-state (path)
  "Return the recoverable current state of PATH."
  (cond
   ((file-symlink-p path)
    (let ((target (file-symlink-p path)))
      (list :kind 'symlink
            :digest (secure-hash 'sha256 target)
            :link target)))
   ((file-regular-p path)
    (list :kind 'file
          :digest (chat-checkpoint--file-digest path)
          :mode (file-modes path)))
   ((not (file-exists-p path))
    (list :kind 'absent :digest nil))
   (t
    (signal 'chat-checkpoint-invalid
            (list "unsupported checkpoint path type" path)))))

(defun chat-checkpoint--relative-path (checkpoint path)
  "Return PATH relative to CHECKPOINT workspace after containment checks."
  (let* ((root (chat-checkpoint-workspace-root checkpoint))
         (root (and root (file-name-as-directory (file-truename root))))
         (expanded (expand-file-name path))
         ;; Resolve the containing directory, but preserve the final path
         ;; component.  A symlink is an owned object in its own right; following
         ;; it here would checkpoint its target under the wrong relative name.
         (parent (file-name-directory expanded))
         (existing
          (if (file-directory-p parent)
              (expand-file-name (file-name-nondirectory expanded)
                                (file-truename parent))
            (let ((ancestor parent))
              (while (and (not (file-exists-p ancestor))
                          (not (string= ancestor "/")))
                (setq ancestor
                      (directory-file-name
                       (file-name-directory ancestor))))
              (expand-file-name
               (file-relative-name expanded ancestor)
               (file-truename ancestor))))))
    (unless (and root
                 (string-prefix-p root
                                  (file-name-as-directory existing)))
      (signal 'chat-checkpoint-workspace-mismatch
              (list expanded root)))
    (file-relative-name existing root)))

(defun chat-checkpoint--absolute-path (checkpoint entry)
  "Return absolute path for checkpoint file ENTRY."
  (let* ((relative (chat-checkpoint-file-path entry))
         (root (chat-checkpoint-workspace-root checkpoint))
         (path (and (stringp relative)
                    root
                    (expand-file-name relative root))))
    (unless (and path
                 (not (file-name-absolute-p relative))
                 (equal relative
                        (chat-checkpoint--relative-path checkpoint path)))
      (signal 'chat-checkpoint-workspace-mismatch
              (list relative root)))
    path))

(defun chat-checkpoint--snapshot-name (relative-path)
  "Return stable snapshot file name for RELATIVE-PATH."
  (secure-hash 'sha256 relative-path))

(defun chat-checkpoint--file-to-json (entry)
  "Return JSON-friendly data for file ENTRY."
  `((schemaVersion . ,(chat-checkpoint-file-schema-version entry))
    (path . ,(chat-checkpoint-file-path entry))
    (status . ,(symbol-name (chat-checkpoint-file-status entry)))
    (originalKind . ,(symbol-name (chat-checkpoint-file-original-kind entry)))
    (originalDigest . ,(chat-checkpoint-file-original-digest entry))
    (originalMode . ,(chat-checkpoint-file-original-mode entry))
    (originalLink . ,(chat-checkpoint-file-original-link entry))
    (snapshot . ,(chat-checkpoint-file-snapshot entry))
    (postKind . ,(and (chat-checkpoint-file-post-kind entry)
                      (symbol-name (chat-checkpoint-file-post-kind entry))))
    (postDigest . ,(chat-checkpoint-file-post-digest entry))
    (capturedAt . ,(chat-checkpoint-file-captured-at entry))
    (updatedAt . ,(chat-checkpoint-file-updated-at entry))))

(defun chat-checkpoint--file-from-json (data)
  "Return a checkpoint file entry decoded from DATA."
  (let ((version (or (alist-get 'schemaVersion data) 0)))
    (unless (= version chat-checkpoint-schema-version)
      (error "Unsupported checkpoint file schema version: %s" version))
    (chat-checkpoint-file-create
     :schema-version version
     :path (alist-get 'path data)
     :status (chat-checkpoint--symbol (alist-get 'status data) 'captured)
     :original-kind (chat-checkpoint--symbol
                     (alist-get 'originalKind data) 'absent)
     :original-digest (alist-get 'originalDigest data)
     :original-mode (alist-get 'originalMode data)
     :original-link (alist-get 'originalLink data)
     :snapshot (alist-get 'snapshot data)
     :post-kind (chat-checkpoint--symbol (alist-get 'postKind data) nil)
     :post-digest (alist-get 'postDigest data)
     :captured-at (alist-get 'capturedAt data)
     :updated-at (alist-get 'updatedAt data))))

(defun chat-checkpoint--to-json (checkpoint)
  "Return JSON-friendly data for CHECKPOINT."
  `((schemaVersion . ,(chat-checkpoint-schema-version checkpoint))
    (id . ,(chat-checkpoint-id checkpoint))
    (sessionId . ,(chat-checkpoint-session-id checkpoint))
    (turnId . ,(chat-checkpoint-turn-id checkpoint))
    (reason . ,(symbol-name (chat-checkpoint-reason checkpoint)))
    (status . ,(symbol-name (chat-checkpoint-status checkpoint)))
    (createdAt . ,(chat-checkpoint-created-at checkpoint))
    (updatedAt . ,(chat-checkpoint-updated-at checkpoint))
    (conversationHeadId . ,(chat-checkpoint-conversation-head-id checkpoint))
    (workspaceKind . ,(symbol-name
                       (chat-checkpoint-workspace-kind checkpoint)))
    (workspaceRoot . ,(chat-checkpoint-workspace-root checkpoint))
    (gitHead . ,(chat-checkpoint-git-head checkpoint))
    (gitStatus . ,(chat-checkpoint-git-status checkpoint))
    (files . ,(mapcar #'chat-checkpoint--file-to-json
                      (chat-checkpoint-files checkpoint)))
    (boundaries . ,(chat-checkpoint-boundaries checkpoint))
    (limitations . ,(chat-checkpoint-limitations checkpoint))
    (rollbacks . ,(chat-checkpoint-rollbacks checkpoint))
    (metadata . ,(chat-checkpoint-metadata checkpoint))))

(defun chat-checkpoint--from-json (data)
  "Return a checkpoint decoded from DATA."
  (let ((version (or (alist-get 'schemaVersion data) 0)))
    (unless (= version chat-checkpoint-schema-version)
      (error "Unsupported checkpoint schema version: %s" version))
    (chat-checkpoint-create-record
     :schema-version version
     :id (alist-get 'id data)
     :session-id (alist-get 'sessionId data)
     :turn-id (alist-get 'turnId data)
     :reason (chat-checkpoint--symbol (alist-get 'reason data) 'user-turn)
     :status (chat-checkpoint--symbol (alist-get 'status data) 'active)
     :created-at (alist-get 'createdAt data)
     :updated-at (alist-get 'updatedAt data)
     :conversation-head-id (alist-get 'conversationHeadId data)
     :workspace-kind (chat-checkpoint--symbol
                      (alist-get 'workspaceKind data) 'checkout)
     :workspace-root (alist-get 'workspaceRoot data)
     :git-head (alist-get 'gitHead data)
     :git-status (alist-get 'gitStatus data)
     :files (mapcar #'chat-checkpoint--file-from-json
                    (alist-get 'files data))
     :boundaries (alist-get 'boundaries data)
     :limitations (alist-get 'limitations data)
     :rollbacks (alist-get 'rollbacks data)
     :metadata (alist-get 'metadata data))))

(defun chat-checkpoint-save (checkpoint)
  "Atomically persist CHECKPOINT and return it."
  (setf (chat-checkpoint-updated-at checkpoint)
        (chat-checkpoint--timestamp-ms))
  (let* ((target (chat-checkpoint--record-file checkpoint))
         (directory (file-name-directory target)))
    (make-directory directory t)
    (let ((temp (make-temp-file (expand-file-name ".checkpoint-" directory))))
      (unwind-protect
          (progn
            (with-temp-file temp
              (insert (json-encode (chat-checkpoint--to-json checkpoint))))
            (rename-file temp target t))
        (when (file-exists-p temp)
          (delete-file temp)))))
  (puthash (chat-checkpoint-id checkpoint)
           checkpoint chat-checkpoint--registry)
  checkpoint)

(defun chat-checkpoint--maybe-save (checkpoint)
  "Persist CHECKPOINT when automatic saving is enabled."
  (when chat-checkpoint-auto-save
    (chat-checkpoint-save checkpoint))
  checkpoint)

(defun chat-checkpoint-load-file (file)
  "Load one checkpoint JSON FILE."
  (let* ((json-array-type 'list)
         (data (with-temp-buffer
                 (insert-file-contents file)
                 (json-read-from-string (buffer-string))))
         (checkpoint (chat-checkpoint--from-json data)))
    (puthash (chat-checkpoint-id checkpoint)
             checkpoint chat-checkpoint--registry)
    checkpoint))

(defun chat-checkpoint-list (&optional session-id)
  "Return checkpoints, optionally limited to SESSION-ID, newest first."
  (let* ((root (if session-id
                   (expand-file-name (concat session-id "/")
                                     chat-checkpoint-directory)
                 chat-checkpoint-directory))
         checkpoints)
    (when (file-directory-p root)
      (dolist (file (directory-files-recursively
                     root "\\`checkpoint\\.json\\'"))
        (condition-case nil
            (push (chat-checkpoint-load-file file) checkpoints)
          (error nil))))
    (sort (delete-dups checkpoints)
          (lambda (left right)
            (> (or (chat-checkpoint-created-at left) 0)
               (or (chat-checkpoint-created-at right) 0))))))

(defun chat-checkpoint-get (id &optional session-id)
  "Return checkpoint ID, loading SESSION-ID records when needed."
  (or (gethash id chat-checkpoint--registry)
      (seq-find (lambda (checkpoint)
                  (equal (chat-checkpoint-id checkpoint) id))
                (chat-checkpoint-list session-id))))

(defun chat-checkpoint--event (checkpoint type &optional extra)
  "Publish TYPE for CHECKPOINT with bounded EXTRA payload entries."
  (chat-event-emit
   type
   :session-id (chat-checkpoint-session-id checkpoint)
   :turn-id (chat-checkpoint-turn-id checkpoint)
   :source 'checkpoint
   :payload
   (append
    (list (cons 'checkpoint_id (chat-checkpoint-id checkpoint))
          (cons 'reason (symbol-name (chat-checkpoint-reason checkpoint)))
          (cons 'status (symbol-name (chat-checkpoint-status checkpoint)))
          (cons 'owned_files
                (seq-count
                 (lambda (entry)
                   (eq (chat-checkpoint-file-status entry) 'owned))
                 (chat-checkpoint-files checkpoint))))
    extra)))

(cl-defun chat-checkpoint-create
    (session &key turn-id (reason 'user-turn) metadata)
  "Create and persist a checkpoint for SESSION before TURN-ID."
  (unless (chat-session-p session)
    (signal 'chat-checkpoint-invalid (list "session" session)))
  (let* ((root (chat-checkpoint--workspace-root session))
         (git (chat-checkpoint--git-observation root))
         (messages (chat-session-messages session))
         (now (chat-checkpoint--timestamp-ms))
         (checkpoint
          (chat-checkpoint-create-record
           :id (chat-checkpoint-new-id)
           :session-id (chat-session-id session)
           :turn-id turn-id
           :reason reason
           :created-at now
           :updated-at now
           :conversation-head-id
           (and messages (chat-message-id (car (last messages))))
           :workspace-kind (chat-checkpoint--workspace-kind session)
           :workspace-root root
           :git-head (car git)
           :git-status (cadr git)
           :metadata metadata)))
    (chat-checkpoint-save checkpoint)
    (let ((ids (copy-sequence
                (or (chat-session-metadata-get session 'checkpoint-ids) nil))))
      (unless (member (chat-checkpoint-id checkpoint) ids)
        (setq ids (append ids (list (chat-checkpoint-id checkpoint)))))
      (chat-session-metadata-set session 'checkpoint-ids ids)
      (chat-session-metadata-set session 'latest-checkpoint-id
                                 (chat-checkpoint-id checkpoint)))
    (chat-session-save session)
    (chat-checkpoint--event checkpoint 'checkpoint-created)
    checkpoint))

(defun chat-checkpoint-for-turn (session turn-id)
  "Return SESSION checkpoint for TURN-ID, or its latest checkpoint."
  (let* ((session-id (chat-session-id session))
         (checkpoints (chat-checkpoint-list session-id)))
    (or (seq-find (lambda (checkpoint)
                    (equal (chat-checkpoint-turn-id checkpoint) turn-id))
                  checkpoints)
        (when (null turn-id)
          (when-let* ((id (chat-session-metadata-get
                           session 'latest-checkpoint-id)))
            (chat-checkpoint-get id session-id))))))

(defun chat-checkpoint--find-file (checkpoint relative-path)
  "Return CHECKPOINT file entry for RELATIVE-PATH."
  (seq-find (lambda (entry)
              (equal (chat-checkpoint-file-path entry) relative-path))
            (chat-checkpoint-files checkpoint)))

(defun chat-checkpoint-capture-path (checkpoint path)
  "Capture PATH before its first direct write in CHECKPOINT."
  (let* ((relative (chat-checkpoint--relative-path checkpoint path))
         (existing (chat-checkpoint--find-file checkpoint relative)))
    (when (and existing
               (eq (chat-checkpoint-file-status existing) 'owned)
               (not (chat-checkpoint--current-matches-post-p
                     existing (chat-checkpoint--path-state path))))
      (signal 'chat-checkpoint-external-drift (list relative)))
    (or existing
        (let* ((state (chat-checkpoint--path-state path))
               (kind (plist-get state :kind))
               (snapshot-name
                (and (eq kind 'file)
                     (chat-checkpoint--snapshot-name relative)))
               (entry
                (chat-checkpoint-file-create
                 :path relative
                 :status 'captured
                 :original-kind kind
                 :original-digest (plist-get state :digest)
                 :original-mode (plist-get state :mode)
                 :original-link (plist-get state :link)
                 :snapshot snapshot-name
                 :captured-at (chat-checkpoint--timestamp-ms))))
          (when snapshot-name
            (let ((snapshot (expand-file-name
                             snapshot-name
                             (chat-checkpoint--snapshot-directory checkpoint))))
              (make-directory (file-name-directory snapshot) t)
              (copy-file path snapshot t t t)))
          (setf (chat-checkpoint-files checkpoint)
                (append (chat-checkpoint-files checkpoint) (list entry)))
          (chat-checkpoint--maybe-save checkpoint)
          (chat-checkpoint--event
           checkpoint 'checkpoint-file-captured
           (list (cons 'path relative) (cons 'original_kind kind)))
          entry))))

(defun chat-checkpoint-capture-paths (checkpoint paths)
  "Capture every PATH in CHECKPOINT before execution."
  (mapcar (lambda (path)
            (chat-checkpoint-capture-path checkpoint path))
          (delete-dups paths)))

(defun chat-checkpoint--write-tool-p (tool-id)
  "Return non-nil when TOOL-ID has precise direct file targets."
  (memq tool-id '(files_write files_replace files_patch apply_patch)))

(defun chat-checkpoint--opaque-tool-p (tool-id)
  "Return non-nil when TOOL-ID may change files without precise targets."
  (memq tool-id '(shell_execute background_task_start workflow_execute
                  subagent_start subagent_external_start)))

(defun chat-checkpoint--call-tool-id (call)
  "Return CALL's tool ID symbol."
  (chat-checkpoint--symbol (plist-get call :name)))

(defun chat-checkpoint--call-arguments (call)
  "Return CALL arguments as an alist."
  (let ((arguments (plist-get call :arguments)))
    (cond ((hash-table-p arguments)
           (let (alist)
             (maphash (lambda (key value)
                        (push (cons (format "%s" key) value) alist))
                      arguments)
             (nreverse alist)))
          ((listp arguments) arguments)
          (t nil))))

(defun chat-checkpoint-add-limitation (checkpoint kind &optional detail)
  "Record coverage limitation KIND and bounded DETAIL on CHECKPOINT."
  (let* ((short-detail
          (and detail
               (truncate-string-to-width
                (format "%s" detail) 512 nil nil t)))
         (entry
          `((kind . ,(symbol-name kind))
            (detail . ,short-detail)
            (timestamp . ,(chat-checkpoint--timestamp-ms)))))
    (unless (seq-some
             (lambda (existing)
               (and (equal (alist-get 'kind existing) (symbol-name kind))
                    (equal (alist-get 'detail existing) short-detail)))
             (chat-checkpoint-limitations checkpoint))
      (setf (chat-checkpoint-limitations checkpoint)
            (append (chat-checkpoint-limitations checkpoint) (list entry)))
      (chat-checkpoint--maybe-save checkpoint))
    checkpoint))

(defun chat-checkpoint-before-tool (session turn-id call)
  "Capture precise targets for CALL before it executes in SESSION TURN-ID."
  (when-let* ((checkpoint (chat-checkpoint-for-turn session turn-id)))
    (let ((tool-id (chat-checkpoint--call-tool-id call)))
      (cond
       ((chat-checkpoint--write-tool-p tool-id)
        (unless (require 'chat-files nil t)
          (error "File tools are unavailable for checkpoint capture"))
        (let ((paths (chat-files--tool-target-paths
                      tool-id (chat-checkpoint--call-arguments call))))
          (unless paths
            (error "Checkpoint could not resolve targets for %s" tool-id))
          (chat-checkpoint-capture-paths checkpoint paths)))
       ((chat-checkpoint--opaque-tool-p tool-id)
        (chat-checkpoint-add-limitation
         checkpoint 'opaque-execution
         (format "%s may modify paths outside direct file ownership" tool-id))))
      checkpoint)))

(defun chat-checkpoint-complete-tool (session turn-id call)
  "Mark successfully written CALL targets as owned in SESSION TURN-ID."
  (when-let* ((checkpoint (chat-checkpoint-for-turn session turn-id)))
    (let ((tool-id (chat-checkpoint--call-tool-id call)))
      (when (chat-checkpoint--write-tool-p tool-id)
        (chat-checkpoint-complete-paths
         checkpoint
         (chat-files--tool-target-paths
          tool-id (chat-checkpoint--call-arguments call))))
      checkpoint)))

(defun chat-checkpoint-complete-paths (checkpoint paths)
  "Mark successfully written PATHS as owned by CHECKPOINT."
  (dolist (path paths)
    (let* ((relative (chat-checkpoint--relative-path checkpoint path))
           (entry (chat-checkpoint--find-file checkpoint relative))
           (state (chat-checkpoint--path-state path)))
      (unless entry
        (error "Checkpoint target was not captured before write: %s"
               relative))
      (setf (chat-checkpoint-file-status entry) 'owned
            (chat-checkpoint-file-post-kind entry) (plist-get state :kind)
            (chat-checkpoint-file-post-digest entry) (plist-get state :digest)
            (chat-checkpoint-file-updated-at entry)
            (chat-checkpoint--timestamp-ms))))
  (chat-checkpoint--maybe-save checkpoint)
  (chat-checkpoint--event checkpoint 'checkpoint-updated)
  checkpoint)

(defun chat-checkpoint-add-boundary (checkpoint type event)
  "Append lifecycle boundary TYPE from EVENT to CHECKPOINT."
  (let ((entry
         (delq nil
               (list (cons 'type (symbol-name type))
                     (cons 'eventId (chat-event-id event))
                     (cons 'taskId (chat-event-task-id event))
                     (cons 'timestamp (chat-event-timestamp-ms event))))))
    (setf (chat-checkpoint-boundaries checkpoint)
          (append (chat-checkpoint-boundaries checkpoint) (list entry)))
    (chat-checkpoint--maybe-save checkpoint)
    checkpoint))

(defun chat-checkpoint-observe-event (event)
  "Attach relevant lifecycle EVENT boundaries to the current checkpoint."
  (when (memq (chat-event-type event)
              '(permission-requested task-ended turn-failed))
    (when-let* ((session-id (chat-event-session-id event))
                (session (chat-session-get session-id))
                (checkpoint (chat-checkpoint-for-turn
                             session (chat-event-turn-id event))))
      (chat-checkpoint-add-boundary
       checkpoint (pcase (chat-event-type event)
                    ('permission-requested 'waiting-approval)
                    ('task-ended 'external-completion)
                    (_ 'interruption))
       event))))

(defun chat-checkpoint-install ()
  "Install checkpoint lifecycle observation once."
  (chat-event-add-observer #'chat-checkpoint-observe-event))

(defun chat-checkpoint--current-matches-post-p (entry state)
  "Return non-nil when ENTRY post-state equals current STATE."
  (and (eq (chat-checkpoint-file-post-kind entry)
           (plist-get state :kind))
       (equal (chat-checkpoint-file-post-digest entry)
              (plist-get state :digest))))

(defun chat-checkpoint--restore-entry (checkpoint entry)
  "Restore owned ENTRY from CHECKPOINT."
  (let* ((path (chat-checkpoint--absolute-path checkpoint entry))
         (kind (chat-checkpoint-file-original-kind entry)))
    (when (or (file-exists-p path) (file-symlink-p path))
      (if (file-directory-p path)
          (signal 'chat-checkpoint-invalid
                  (list "refusing to replace directory" path))
        (delete-file path)))
    (pcase kind
      ('absent nil)
      ('file
       (let ((snapshot
              (expand-file-name
               (chat-checkpoint-file-snapshot entry)
               (chat-checkpoint--snapshot-directory checkpoint))))
         (unless (file-regular-p snapshot)
           (signal 'chat-checkpoint-invalid
                   (list "missing checkpoint snapshot" snapshot)))
         (make-directory (file-name-directory path) t)
         (copy-file snapshot path t t t)
         (when (chat-checkpoint-file-original-mode entry)
           (set-file-modes path (chat-checkpoint-file-original-mode entry)))))
      ('symlink
       (make-directory (file-name-directory path) t)
       (make-symbolic-link (chat-checkpoint-file-original-link entry)
                           path))
      (_ (signal 'chat-checkpoint-invalid (list "original kind" kind))))
    path))

(defun chat-checkpoint--original-restored-p (checkpoint entry)
  "Return non-nil when ENTRY original state is restored in CHECKPOINT."
  (let ((state (chat-checkpoint--path-state
                (chat-checkpoint--absolute-path checkpoint entry))))
    (and (eq (chat-checkpoint-file-original-kind entry)
             (plist-get state :kind))
         (equal (chat-checkpoint-file-original-digest entry)
                (plist-get state :digest))
         (or (not (eq (chat-checkpoint-file-original-kind entry) 'file))
             (= (chat-checkpoint-file-original-mode entry)
                (plist-get state :mode))))))

(defun chat-checkpoint--record-rollback
    (checkpoint scope status &optional details)
  "Record CHECKPOINT rollback SCOPE, STATUS and DETAILS."
  (let ((entry
         `((scope . ,(symbol-name scope))
           (status . ,(symbol-name status))
           (timestamp . ,(chat-checkpoint--timestamp-ms))
           (details . ,details))))
    (setf (chat-checkpoint-rollbacks checkpoint)
          (append (chat-checkpoint-rollbacks checkpoint) (list entry)))
    (when (eq status 'completed)
      (setf (chat-checkpoint-status checkpoint) 'rolled-back))
    (chat-checkpoint--maybe-save checkpoint)
    (chat-checkpoint--event
     checkpoint 'checkpoint-rolled-back
     (list (cons 'scope (symbol-name scope))
           (cons 'rollback_status (symbol-name status))))
    entry))

(defun chat-checkpoint-rollback-code (checkpoint &optional force)
  "Restore CHECKPOINT owned files, refusing drift unless FORCE is non-nil."
  (let ((root (chat-checkpoint-workspace-root checkpoint))
        (owned (seq-filter
                (lambda (entry)
                  (eq (chat-checkpoint-file-status entry) 'owned))
                (chat-checkpoint-files checkpoint)))
        drift)
    (unless (and root (file-directory-p root))
      (signal 'chat-checkpoint-workspace-mismatch (list root)))
    (dolist (entry owned)
      (let* ((path (chat-checkpoint--absolute-path checkpoint entry))
             (state (chat-checkpoint--path-state path)))
        (unless (or (chat-checkpoint--current-matches-post-p entry state)
                    (chat-checkpoint--original-restored-p checkpoint entry))
          (push (chat-checkpoint-file-path entry) drift))))
    (when (and drift (not force))
      (chat-checkpoint--record-rollback
       checkpoint 'code 'refused
       `((externalDrift . ,(nreverse drift))))
      (signal 'chat-checkpoint-external-drift (list (nreverse drift))))
    (dolist (entry owned)
      (chat-checkpoint--restore-entry checkpoint entry))
    (let ((failed
           (delq nil
                 (mapcar
                  (lambda (entry)
                    (unless (chat-checkpoint--original-restored-p
                             checkpoint entry)
                      (chat-checkpoint-file-path entry)))
                  owned))))
      (when failed
        (chat-checkpoint--record-rollback
         checkpoint 'code 'failed `((verificationFailed . ,failed)))
        (signal 'chat-checkpoint-invalid
                (list "rollback verification failed" failed))))
    (chat-checkpoint--record-rollback
     checkpoint 'code 'completed
     `((restoredFiles . ,(length owned))
       (forced . ,(and force t))))
    (list :checkpoint-id (chat-checkpoint-id checkpoint)
          :scope 'code
          :restored-files (length owned)
          :forced (and force t)
          :limitations (chat-checkpoint-limitations checkpoint))))

(defun chat-checkpoint-rollback-conversation (checkpoint session)
  "Create a conversation branch of SESSION at CHECKPOINT."
  (unless (equal (chat-checkpoint-session-id checkpoint)
                 (chat-session-id session))
    (signal 'chat-checkpoint-invalid
            (list "checkpoint session mismatch")))
  (let ((branch
         (chat-session-create-branch
          session
          (chat-checkpoint-conversation-head-id checkpoint)
          (format "%s / recovery" (chat-session-name session))
          `((rollback-checkpoint-id . ,(chat-checkpoint-id checkpoint))))))
    (chat-checkpoint--record-rollback
     checkpoint 'conversation 'completed
     `((branchSessionId . ,(chat-session-id branch))))
    branch))

(defun chat-checkpoint-rollback-both (checkpoint session &optional force)
  "Roll back CHECKPOINT code, then create a SESSION conversation branch."
  (let ((code-result (chat-checkpoint-rollback-code checkpoint force))
        (branch (chat-checkpoint-rollback-conversation checkpoint session)))
    (list :checkpoint-id (chat-checkpoint-id checkpoint)
          :scope 'both
          :code code-result
          :branch branch)))

(provide 'chat-checkpoint)
;;; chat-checkpoint.el ends here
