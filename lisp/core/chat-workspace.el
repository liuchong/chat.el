;;; chat-workspace.el --- Session-owned worktree lifecycle -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;;; Commentary:

;; Optional worktree sessions protect the source checkout without pretending
;; to provide operating-system isolation.  Ownership and cleanup conditions
;; are durable and verified before Git is asked to remove anything.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'chat-event)
(require 'chat-session)

(declare-function chat-code-session-set-project-root
                  "chat-code" (session value))

(defgroup chat-workspace nil
  "Session workspace ownership and worktree lifecycle."
  :group 'chat)

(defconst chat-workspace-schema-version 1
  "Current workspace ownership schema version.")

(defcustom chat-workspace-directory
  (expand-file-name "workspaces/" (expand-file-name "~/.chat/"))
  "Directory containing durable workspace ownership records."
  :type 'directory
  :group 'chat-workspace)

(defcustom chat-worktree-directory
  (expand-file-name "worktrees/" (expand-file-name "~/.chat/"))
  "Root under which runtime-owned Git worktrees are created."
  :type 'directory
  :group 'chat-workspace)

(defcustom chat-workspace-auto-save t
  "When non-nil, persist workspace records after every transition."
  :type 'boolean
  :group 'chat-workspace)

(define-error 'chat-workspace-invalid "Invalid workspace ownership record")
(define-error 'chat-workspace-dirty "Owned worktree contains changes")
(define-error 'chat-workspace-ownership-mismatch
  "Worktree ownership could not be verified")

(cl-defstruct
    (chat-workspace
     (:constructor chat-workspace-create-record
                   (&key (schema-version chat-workspace-schema-version)
                         id session-id (kind 'worktree) source-root path
                         base-revision (status 'active) created-at
                         reconciled-at released-at dirty metadata)))
  "One durable session workspace ownership record."
  schema-version id session-id kind source-root path base-revision status
  created-at reconciled-at released-at dirty metadata)

(defvar chat-workspace--registry (make-hash-table :test 'equal)
  "Workspace records keyed by owner session ID.")

(defvar chat-workspace--id-sequence 0
  "Process-local suffix for workspace IDs.")

(defun chat-workspace--timestamp-ms ()
  "Return the current Unix time in milliseconds."
  (round (* 1000 (float-time))))

(defun chat-workspace-new-id ()
  "Return a fresh workspace ownership ID."
  (format "workspace-%d-%d"
          (chat-workspace--timestamp-ms)
          (cl-incf chat-workspace--id-sequence)))

(defun chat-workspace--symbol (value &optional fallback)
  "Return VALUE as a symbol, or FALLBACK."
  (cond ((symbolp value) value)
        ((and (stringp value) (not (string-empty-p value))) (intern value))
        (t fallback)))

(defun chat-workspace--git (root &rest args)
  "Run Git ARGS at ROOT and return output, signaling on failure."
  (with-temp-buffer
    (let ((status (apply #'process-file "git" nil t nil
                         "-C" root args))
          output)
      (setq output (string-trim-right (buffer-string)))
      (unless (zerop status)
        (error "Git failed (%d): %s" status output))
      output)))

(defun chat-workspace--git-root (path)
  "Return canonical Git root containing PATH."
  (let ((root (chat-workspace--git
               (expand-file-name path) "rev-parse" "--show-toplevel")))
    (file-name-as-directory (file-truename root))))

(defun chat-workspace--default-path (source-root session-id)
  "Return owned worktree path for SOURCE-ROOT and SESSION-ID."
  (let ((repo-key (substring (secure-hash 'sha256 source-root) 0 16)))
    (file-name-as-directory
     (expand-file-name
      session-id
      (expand-file-name repo-key chat-worktree-directory)))))

(defun chat-workspace--state-file ()
  "Return durable workspace state file."
  (expand-file-name "records.json" chat-workspace-directory))

(defun chat-workspace--to-json (workspace)
  "Return JSON-friendly data for WORKSPACE."
  `((schemaVersion . ,(chat-workspace-schema-version workspace))
    (id . ,(chat-workspace-id workspace))
    (sessionId . ,(chat-workspace-session-id workspace))
    (kind . ,(symbol-name (chat-workspace-kind workspace)))
    (sourceRoot . ,(chat-workspace-source-root workspace))
    (path . ,(chat-workspace-path workspace))
    (baseRevision . ,(chat-workspace-base-revision workspace))
    (status . ,(symbol-name (chat-workspace-status workspace)))
    (createdAt . ,(chat-workspace-created-at workspace))
    (reconciledAt . ,(chat-workspace-reconciled-at workspace))
    (releasedAt . ,(chat-workspace-released-at workspace))
    (dirty . ,(and (chat-workspace-dirty workspace) t))
    (metadata . ,(chat-workspace-metadata workspace))))

(defun chat-workspace--from-json (data)
  "Return a workspace record decoded from DATA."
  (let ((version (or (alist-get 'schemaVersion data) 0)))
    (unless (= version chat-workspace-schema-version)
      (error "Unsupported workspace schema version: %s" version))
    (chat-workspace-create-record
     :schema-version version
     :id (alist-get 'id data)
     :session-id (alist-get 'sessionId data)
     :kind (chat-workspace--symbol (alist-get 'kind data) 'worktree)
     :source-root (alist-get 'sourceRoot data)
     :path (alist-get 'path data)
     :base-revision (alist-get 'baseRevision data)
     :status (chat-workspace--symbol (alist-get 'status data) 'needs-attention)
     :created-at (alist-get 'createdAt data)
     :reconciled-at (alist-get 'reconciledAt data)
     :released-at (alist-get 'releasedAt data)
     :dirty (eq (alist-get 'dirty data) t)
     :metadata (alist-get 'metadata data))))

(defun chat-workspace-save ()
  "Atomically persist all workspace records."
  (make-directory chat-workspace-directory t)
  (let* ((target (chat-workspace--state-file))
         (temp (make-temp-file
                (expand-file-name ".workspaces-" chat-workspace-directory)))
         records)
    (unwind-protect
        (progn
          (maphash (lambda (_session-id workspace)
                     (push workspace records))
                   chat-workspace--registry)
          (setq records
                (sort records
                      (lambda (left right)
                        (string< (chat-workspace-session-id left)
                                 (chat-workspace-session-id right)))))
          (with-temp-file temp
            (insert
             (json-encode
              `((schemaVersion . ,chat-workspace-schema-version)
                (records . ,(mapcar #'chat-workspace--to-json records))))))
          (rename-file temp target t))
      (when (file-exists-p temp)
        (delete-file temp))))
  t)

(defun chat-workspace--maybe-save ()
  "Persist workspace records when automatic saving is enabled."
  (when chat-workspace-auto-save
    (chat-workspace-save)))

(defun chat-workspace-load ()
  "Load durable workspace records without creating or removing worktrees."
  (clrhash chat-workspace--registry)
  (let ((file (chat-workspace--state-file)))
    (when (file-exists-p file)
      (let* ((json-array-type 'list)
             (data (with-temp-buffer
                     (insert-file-contents file)
                     (json-read-from-string (buffer-string))))
             (version (or (alist-get 'schemaVersion data) 0)))
        (unless (= version chat-workspace-schema-version)
          (error "Unsupported workspace state schema version: %s" version))
        (dolist (entry (alist-get 'records data))
          (let ((workspace (chat-workspace--from-json entry)))
            (puthash (chat-workspace-session-id workspace)
                     workspace chat-workspace--registry))))))
  (hash-table-count chat-workspace--registry))

(defun chat-workspace-get (session-or-id)
  "Return workspace owned by SESSION-OR-ID, or nil."
  (gethash (if (chat-session-p session-or-id)
               (chat-session-id session-or-id)
             session-or-id)
           chat-workspace--registry))

(defun chat-workspace-list ()
  "Return workspace records ordered by creation time."
  (let (records)
    (maphash (lambda (_id workspace) (push workspace records))
             chat-workspace--registry)
    (sort records
          (lambda (left right)
            (< (or (chat-workspace-created-at left) 0)
               (or (chat-workspace-created-at right) 0))))))

(defun chat-workspace--event (workspace type &optional reason)
  "Publish TYPE for WORKSPACE and optional REASON."
  (chat-event-emit
   type
   :session-id (chat-workspace-session-id workspace)
   :source 'workspace
   :payload
   (delq nil
         (list (cons 'workspace_id (chat-workspace-id workspace))
               (cons 'kind (symbol-name (chat-workspace-kind workspace)))
               (cons 'status (symbol-name (chat-workspace-status workspace)))
               (cons 'dirty (and (chat-workspace-dirty workspace) t))
               (and reason
                    (cons 'reason
                          (truncate-string-to-width
                           (format "%s" reason) 512 nil nil t)))))))

(defun chat-workspace--metadata (workspace)
  "Return session metadata representation for WORKSPACE."
  `((schemaVersion . ,chat-workspace-schema-version)
    (id . ,(chat-workspace-id workspace))
    (kind . ,(symbol-name (chat-workspace-kind workspace)))
    (sourceRoot . ,(chat-workspace-source-root workspace))
    (path . ,(chat-workspace-path workspace))
    (baseRevision . ,(chat-workspace-base-revision workspace))
    (status . ,(symbol-name (chat-workspace-status workspace)))))

(defun chat-workspace--update-session (session workspace directory)
  "Update SESSION for WORKSPACE and active DIRECTORY."
  (chat-session-metadata-set session 'workspace
                             (chat-workspace--metadata workspace))
  (chat-session-metadata-set session 'working-directory
                             (file-name-as-directory directory))
  (if (fboundp 'chat-code-session-set-project-root)
      (chat-code-session-set-project-root
       session (file-name-as-directory directory))
    (chat-session-metadata-set session 'project-root
                               (file-name-as-directory directory)))
  (chat-session-save session)
  session)

(defun chat-workspace--registered-paths (source-root)
  "Return canonical worktree paths registered under SOURCE-ROOT."
  (let ((output (chat-workspace--git
                 source-root "worktree" "list" "--porcelain"))
        paths)
    (dolist (line (split-string output "\n" t))
      (when (string-prefix-p "worktree " line)
        (let ((path (substring line (length "worktree "))))
          (push (file-name-as-directory (file-truename path)) paths))))
    (nreverse paths)))

(defun chat-workspace--path-under-owned-root-p (path)
  "Return non-nil when PATH is under `chat-worktree-directory'."
  (make-directory chat-worktree-directory t)
  (let ((root (file-name-as-directory
               (file-truename chat-worktree-directory)))
        (expanded (file-name-as-directory
                   (if (file-exists-p path)
                       (file-truename path)
                     (expand-file-name path)))))
    (string-prefix-p root expanded)))

(defun chat-workspace--registered-p (workspace)
  "Return non-nil when Git registers WORKSPACE at its owned path."
  (and (file-directory-p (chat-workspace-path workspace))
       (member (file-name-as-directory
                (file-truename (chat-workspace-path workspace)))
               (chat-workspace--registered-paths
                (chat-workspace-source-root workspace)))))

(defun chat-workspace--dirty-p (workspace)
  "Return non-nil when WORKSPACE worktree contains changes."
  (and (file-directory-p (chat-workspace-path workspace))
       (not (string-empty-p
             (chat-workspace--git
              (chat-workspace-path workspace)
              "status" "--porcelain=v1" "--untracked-files=all")))))

(cl-defun chat-workspace-enable-worktree
    (session source-root &key revision)
  "Create and assign an owned worktree to SESSION from SOURCE-ROOT.

REVISION defaults to the source repository HEAD.  Source working-tree changes
are neither copied nor modified."
  (unless (chat-session-p session)
    (signal 'chat-workspace-invalid (list "session" session)))
  (when-let* ((existing (chat-workspace-get session)))
    (unless (eq (chat-workspace-status existing) 'released)
      (error "Session already owns workspace %s"
             (chat-workspace-id existing))))
  (let* ((source-root (chat-workspace--git-root source-root))
         (base (chat-workspace--git
                source-root "rev-parse" "--verify" (or revision "HEAD")))
         (path (chat-workspace--default-path
                source-root (chat-session-id session)))
         (now (chat-workspace--timestamp-ms))
         workspace)
    (when (file-exists-p path)
      (signal 'chat-workspace-ownership-mismatch
              (list "owned path already exists" path)))
    (make-directory (file-name-directory (directory-file-name path)) t)
    (chat-workspace--git
     source-root "worktree" "add" "--detach" path base)
    (setq workspace
          (chat-workspace-create-record
           :id (chat-workspace-new-id)
           :session-id (chat-session-id session)
           :source-root source-root
           :path path
           :base-revision base
           :status 'active
           :created-at now
           :reconciled-at now
           :dirty nil))
    (unless (and (chat-workspace--path-under-owned-root-p path)
                 (chat-workspace--registered-p workspace))
      (ignore-errors
        (chat-workspace--git source-root "worktree" "remove" "--force" path))
      (signal 'chat-workspace-ownership-mismatch (list path)))
    (puthash (chat-session-id session) workspace chat-workspace--registry)
    (chat-workspace--maybe-save)
    (chat-workspace--update-session session workspace path)
    (chat-workspace--event workspace 'workspace-created)
    workspace))

(defun chat-workspace-reconcile (workspace &optional session)
  "Reconcile durable WORKSPACE ownership and optionally update SESSION."
  (let ((reason nil))
    (cond
     ((eq (chat-workspace-status workspace) 'released) nil)
     ((not (chat-workspace--path-under-owned-root-p
            (chat-workspace-path workspace)))
      (setf (chat-workspace-status workspace) 'needs-attention)
      (setq reason "path is outside the runtime-owned root"))
     ((not (file-directory-p (chat-workspace-path workspace)))
      (setf (chat-workspace-status workspace) 'needs-attention)
      (setq reason "owned worktree path is missing"))
     ((not (condition-case nil
               (chat-workspace--registered-p workspace)
             (error nil)))
      (setf (chat-workspace-status workspace) 'needs-attention)
      (setq reason "Git no longer registers the owned worktree"))
     (t
      (setf (chat-workspace-status workspace) 'active
            (chat-workspace-dirty workspace)
            (chat-workspace--dirty-p workspace))))
    (setf (chat-workspace-reconciled-at workspace)
          (chat-workspace--timestamp-ms))
    (chat-workspace--maybe-save)
    (when (and session
               (eq (chat-workspace-status workspace) 'active))
      (chat-workspace--update-session
       session workspace (chat-workspace-path workspace)))
    (chat-workspace--event workspace 'workspace-reconciled reason)
    workspace))

(defun chat-workspace-reconcile-all ()
  "Reconcile every loaded workspace without creating live resources."
  (dolist (workspace (chat-workspace-list))
    (chat-workspace-reconcile
     workspace
     (chat-session-get (chat-workspace-session-id workspace))))
  (chat-workspace-list))

(defun chat-workspace-release (session &optional force)
  "Release SESSION's owned worktree, refusing dirty state unless FORCE."
  (let ((workspace (chat-workspace-get session)))
    (unless workspace
      (error "Session owns no worktree"))
    (unless (eq (chat-workspace-status workspace) 'released)
      (unless (and (chat-workspace--path-under-owned-root-p
                    (chat-workspace-path workspace))
                   (chat-workspace--registered-p workspace))
        (setf (chat-workspace-status workspace) 'needs-attention)
        (chat-workspace--maybe-save)
        (signal 'chat-workspace-ownership-mismatch
                (list (chat-workspace-path workspace))))
      (let ((dirty (chat-workspace--dirty-p workspace)))
        (setf (chat-workspace-dirty workspace) dirty)
        (when (and dirty (not force))
          (setf (chat-workspace-status workspace) 'needs-attention)
          (chat-workspace--maybe-save)
          (chat-workspace--event
           workspace 'workspace-release-refused "worktree is dirty")
          (signal 'chat-workspace-dirty
                  (list (chat-workspace-path workspace)))))
      (apply #'chat-workspace--git
             (chat-workspace-source-root workspace)
             "worktree" "remove"
             (append (when force (list "--force"))
                     (list (chat-workspace-path workspace))))
      (setf (chat-workspace-status workspace) 'released
            (chat-workspace-released-at workspace)
            (chat-workspace--timestamp-ms)
            (chat-workspace-dirty workspace) nil)
      (chat-workspace--maybe-save)
      (chat-workspace--update-session
       session workspace (chat-workspace-source-root workspace))
      (chat-workspace--event
       workspace 'workspace-released (and force "forced release")))
    workspace))

(defun chat-workspace-initialize ()
  "Load and reconcile durable workspace ownership records."
  (chat-workspace-load)
  (chat-workspace-reconcile-all))

(provide 'chat-workspace)
;;; chat-workspace.el ends here
