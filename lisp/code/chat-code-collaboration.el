;;; chat-code-collaboration.el --- Isolated coding-agent collaboration -*- lexical-binding: t; -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;;; Commentary:

;; Coding children declare path ownership and run in session-owned worktrees.
;; Their parent receives only bounded outcomes.  A merge gate validates base
;; revision, ownership, parent drift and patch applicability before changing the
;; source checkout, then reruns project verification.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'chat-event)
(require 'chat-session)
(require 'chat-task)
(require 'chat-workspace)

(defgroup chat-code-collaboration nil
  "Isolated coding-agent collaboration."
  :group 'chat)

(defcustom chat-code-collaboration-summary-limit 4000
  "Maximum child summary characters retained by the parent."
  :type 'integer
  :group 'chat-code-collaboration)

(define-error 'chat-code-collaboration-invalid "Invalid coding child contract")

(cl-defstruct (chat-code-child
               (:constructor chat-code-child-create))
  id task-id goal allowed-paths resources provider model profile budget evidence
  base-revision parent-session child-session workspace status summary
  changed-files verification-id checkpoint-ids error)

(cl-defstruct (chat-code-merge-result
               (:constructor chat-code-merge-result-create))
  child-id status changed-files verification-id reason)

(defvar chat-code-collaboration--children (make-hash-table :test 'equal)
  "Coding children keyed by stable id.")

(defvar chat-code-collaboration-start-agent-function
  #'chat-subagent-start-agent
  "Function used to start coding children.")

(defvar chat-code-collaboration-verification-function
  #'chat-code-collaboration--verify
  "Function called with project root, changed files and session id after merge.")

(defun chat-code-collaboration--new-id ()
  "Return a stable coding child identifier."
  (chat-session-new-message-id "coding-child"))

(defun chat-code-collaboration--bounded (value)
  "Return VALUE as bounded parent-visible text."
  (let ((text (if (stringp value) value (prin1-to-string value))))
    (truncate-string-to-width
     text chat-code-collaboration-summary-limit nil nil t)))

(defun chat-code-collaboration--git (root &rest args)
  "Run Git ARGS in ROOT and return stdout."
  (let ((default-directory (file-name-as-directory (expand-file-name root))))
    (with-temp-buffer
      (let ((exit (apply #'process-file "git" nil t nil args)))
        (unless (zerop exit)
          (error "git %s failed: %s"
                 (string-join args " ") (string-trim (buffer-string))))
        (buffer-string)))))

(defun chat-code-collaboration--root (directory)
  "Return canonical Git root containing DIRECTORY."
  (file-name-as-directory
   (file-truename
    (string-trim
     (chat-code-collaboration--git
      directory "rev-parse" "--show-toplevel")))))

(defun chat-code-collaboration--relative-path (root value)
  "Validate VALUE beneath ROOT and return a normalized relative path."
  (unless (and (stringp value) (not (string-blank-p value)))
    (signal 'chat-code-collaboration-invalid (list "empty allowed path")))
  (let ((absolute (expand-file-name value root)))
    (unless (file-in-directory-p absolute root)
      (signal 'chat-code-collaboration-invalid
              (list (format "path escapes project: %s" value))))
    (directory-file-name (file-relative-name absolute root))))

(defun chat-code-collaboration--path-owned-p (path allowed)
  "Return non-nil when PATH belongs to one of ALLOWED scopes."
  (seq-some
   (lambda (scope)
     (or (equal path scope)
         (string-prefix-p (file-name-as-directory scope) path)))
   allowed))

(defun chat-code-collaboration--resources (root allowed resources)
  "Return normalized RESOURCES plus write locks for ALLOWED paths in ROOT."
  (append
   (mapcar (lambda (path)
             (list :key (concat "path:" (expand-file-name path root))
                   :mode 'write))
           allowed)
   (copy-tree resources)))

(cl-defun chat-code-collaboration-declare
    (parent-session goal allowed-paths
                    &key resources provider model (profile 'code) (budget 12)
                    evidence base-revision)
  "Declare one coding child with explicit ownership and completion evidence."
  (unless (chat-session-p parent-session)
    (signal 'chat-code-collaboration-invalid (list "missing parent session")))
  (unless (and (stringp goal) (not (string-blank-p goal)))
    (signal 'chat-code-collaboration-invalid (list "missing child goal")))
  (unless (and (listp allowed-paths) allowed-paths)
    (signal 'chat-code-collaboration-invalid
            (list "allowed paths must be non-empty")))
  (unless (and (integerp budget) (> budget 0))
    (signal 'chat-code-collaboration-invalid (list "invalid child budget")))
  (let* ((provider (or provider (chat-session-model-id parent-session)))
         (model (or model
                    (and (eq provider (chat-session-model-id parent-session))
                         (chat-session-model-name parent-session))
                    (plist-get (chat-llm-get-provider-config provider) :model)))
         (_identity
          (unless (and (symbolp provider)
                       (stringp model)
                       (not (string-blank-p model)))
            (signal 'chat-code-collaboration-invalid
                    (list "child requires provider and concrete model"))))
         (root (chat-code-collaboration--root
                (chat-session-working-directory parent-session)))
         (allowed (delete-dups
                   (mapcar (lambda (path)
                             (chat-code-collaboration--relative-path root path))
                           allowed-paths)))
         (id (chat-code-collaboration--new-id))
         (base (or base-revision
                   (string-trim
                    (chat-code-collaboration--git root "rev-parse" "HEAD"))))
         (child
          (chat-code-child-create
           :id id :task-id id :goal goal :allowed-paths allowed
           :resources (chat-code-collaboration--resources
                       root allowed resources)
           :provider provider :model model :profile profile
           :budget budget :evidence evidence
           :base-revision base :parent-session parent-session
           :status 'declared)))
    (puthash id child chat-code-collaboration--children)
    child))

(defun chat-code-collaboration-child-data (child)
  "Return the bounded parent-visible contract for CHILD."
  `((id . ,(chat-code-child-id child))
    (status . ,(symbol-name (chat-code-child-status child)))
    (provider . ,(and (chat-code-child-provider child)
                      (symbol-name (chat-code-child-provider child))))
    (model . ,(chat-code-child-model child))
    (summary . ,(and (chat-code-child-summary child)
                     (chat-code-collaboration--bounded
                      (chat-code-child-summary child))))
    (changedFiles . ,(copy-sequence (chat-code-child-changed-files child)))
    (verificationId . ,(chat-code-child-verification-id child))
    (checkpointIds . ,(copy-sequence
                       (chat-code-child-checkpoint-ids child)))
    (error . ,(chat-code-child-error child))))

(defun chat-code-collaboration--prompt (child)
  "Build the bounded child prompt for CHILD."
  (format
   (concat
    "GOAL\n%s\n\nALLOWED WRITE PATHS\n%s\n\nCOMPLETION EVIDENCE\n%s\n\n"
    "Work only inside the assigned worktree. Do not modify paths outside the "
    "allowed list. Return a concise summary and verification facts; do not "
    "return the full transcript.")
   (chat-code-child-goal child)
   (string-join (chat-code-child-allowed-paths child) "\n")
   (chat-code-collaboration--bounded
    (or (chat-code-child-evidence child) "No additional evidence declared."))))

(defun chat-code-collaboration--split-nul (value)
  "Split NUL-delimited VALUE into non-empty strings."
  (split-string value "\0" t))

(defun chat-code-collaboration-changed-files (child)
  "Return canonical changed paths from CHILD's owned worktree."
  (let* ((workspace (chat-code-child-workspace child))
         (root (and workspace (chat-workspace-path workspace)))
         (base (chat-code-child-base-revision child)))
    (unless (and workspace root (file-directory-p root))
      (signal 'chat-code-collaboration-invalid
              (list "child has no active worktree")))
    (sort
     (delete-dups
      (append
       (chat-code-collaboration--split-nul
        (chat-code-collaboration--git
         root "diff" "--name-only" "-z" base "--"))
       (chat-code-collaboration--split-nul
        (chat-code-collaboration--git
         root "ls-files" "--others" "--exclude-standard" "-z"))))
     #'string<)))

(defun chat-code-collaboration--finish-child
    (child complete summary)
  "Validate and finish CHILD, invoking task COMPLETE with bounded SUMMARY."
  (condition-case err
      (let ((changed (chat-code-collaboration-changed-files child)))
        (unless (cl-every
                 (lambda (path)
                   (chat-code-collaboration--path-owned-p
                    path (chat-code-child-allowed-paths child)))
                 changed)
          (signal 'chat-code-collaboration-invalid
                  (list "child changed a path it does not own" changed)))
        (setf (chat-code-child-status child) 'completed
              (chat-code-child-summary child)
              (chat-code-collaboration--bounded summary)
              (chat-code-child-changed-files child) changed)
        (funcall complete (chat-code-collaboration-child-data child)))
    (error
     (setf (chat-code-child-status child) 'blocked
           (chat-code-child-error child) (error-message-string err))
     (signal (car err) (cdr err)))))

(defun chat-code-collaboration-start (child)
  "Queue declared CHILD for conflict-aware isolated execution."
  (unless (eq (chat-code-child-status child) 'declared)
    (signal 'chat-code-collaboration-invalid
            (list "child is not declared" (chat-code-child-status child))))
  (let* ((parent (chat-code-child-parent-session child))
         (root (chat-code-collaboration--root
                (chat-session-working-directory parent)))
         (task
          (chat-task-create
           :id (chat-code-child-task-id child) :kind 'coding-child
           :title (chat-code-child-goal child) :status 'queued
           :session-id (chat-session-id parent) :source 'code-collaboration
           :resources (chat-code-child-resources child)
           :payload
           `((goal . ,(chat-code-collaboration--bounded
                       (chat-code-child-goal child)))
             (allowedPaths . ,(chat-code-child-allowed-paths child))
             (baseRevision . ,(chat-code-child-base-revision child))
             (profile . ,(symbol-name (chat-code-child-profile child)))
             (budget . ,(chat-code-child-budget child))))))
    (chat-task-submit
     task
     (lambda (_task complete fail _attention)
       (setf (chat-code-child-status child) 'running)
       (condition-case err
           (let ((handle
                  (funcall
                   chat-code-collaboration-start-agent-function
                   (format "Coding child %s" (chat-code-child-id child))
                   (chat-code-collaboration--prompt child) parent
                   (lambda (response)
                     (condition-case callback-error
                         (chat-code-collaboration--finish-child
                          child complete
                          (or (alist-get 'summary response) response))
                       (error
                        (setf (chat-code-child-status child) 'blocked
                              (chat-code-child-error child)
                              (error-message-string callback-error))
                        (funcall fail (chat-code-child-error child)))))
                   (lambda (message)
                     (setf (chat-code-child-status child) 'failed
                           (chat-code-child-error child) message)
                     (funcall fail message))
                   (chat-code-child-budget child)
                   (list :profile (chat-code-child-profile child)
                         :provider (chat-code-child-provider child)
                         :model (chat-code-child-model child)
                         :project-root root
                         :base-revision (chat-code-child-base-revision child)))))
             (setf (chat-code-child-child-session child)
                   (plist-get handle :child-session)
                   (chat-code-child-workspace child)
                   (plist-get handle :workspace))
             :async)
         (error
          (let ((message (error-message-string err)))
            (setf (chat-code-child-status child) 'failed
                  (chat-code-child-error child) message)
            (funcall fail message)))))
     (lambda (_task reason)
       (setf (chat-code-child-status child) 'canceled
             (chat-code-child-error child) reason)))
    child))

(defun chat-code-collaboration--parent-changed-files (root base)
  "Return parent paths changed from BASE in ROOT."
  (sort
   (delete-dups
    (append
     (chat-code-collaboration--split-nul
      (chat-code-collaboration--git
       root "diff" "--name-only" "-z" base "--"))
     (chat-code-collaboration--split-nul
      (chat-code-collaboration--git
       root "ls-files" "--others" "--exclude-standard" "-z"))))
   #'string<))

(defun chat-code-collaboration--intersects-p (left right)
  "Return non-nil when path lists LEFT and RIGHT intersect."
  (seq-some (lambda (path) (member path right)) left))

(defun chat-code-collaboration--patch (child)
  "Return a binary patch for CHILD including untracked files."
  (let* ((root (chat-workspace-path (chat-code-child-workspace child)))
         (untracked
          (chat-code-collaboration--split-nul
           (chat-code-collaboration--git
            root "ls-files" "--others" "--exclude-standard" "-z"))))
    (when untracked
      (apply #'chat-code-collaboration--git root
             "add" "--intent-to-add" "--" untracked))
    (chat-code-collaboration--git
     root "diff" "--binary" (chat-code-child-base-revision child) "--")))

(defun chat-code-collaboration--apply-patch (root patch check-only)
  "Apply PATCH in ROOT, or only validate it when CHECK-ONLY is non-nil."
  (let ((default-directory (file-name-as-directory root)))
    (with-temp-buffer
      (insert patch)
      (let ((output (generate-new-buffer " *chat-git-apply*")))
        (unwind-protect
            (let ((exit
                   (apply #'call-process-region
                          (point-min) (point-max) "git" nil output nil
                          (append (list "apply")
                                  (when check-only (list "--check"))
                                  (list "--binary" "--whitespace=nowarn" "-")))))
              (unless (zerop exit)
                (with-current-buffer output
                  (error "git apply%s failed: %s"
                         (if check-only " --check" "")
                         (string-trim (buffer-string))))))
          (kill-buffer output))))))

(defun chat-code-collaboration--verify (root changed session-id)
  "Plan and run required verification for CHANGED paths in ROOT."
  (require 'chat-code-verify)
  (let* ((profile (chat-code-verify-plan
                   root changed (list :session-id session-id)))
         (result (chat-code-verify-run-sync
                  profile (list :session-id session-id
                                :changed-files changed))))
    (list :id (chat-code-verify-result-id result)
          :status (chat-code-verify-result-status result)
          :data (chat-code-verify-result-data result))))

(defun chat-code-collaboration--emit-merge (type child status &optional reason)
  "Emit bounded merge TYPE for CHILD with STATUS and optional REASON."
  (let ((session (chat-code-child-parent-session child)))
    (chat-event-emit
     type :session-id (and session (chat-session-id session))
     :task-id (chat-code-child-task-id child) :source 'code-collaboration
     :subject child
     :payload
     `((child_id . ,(chat-code-child-id child))
       (status . ,(symbol-name status))
       (changed_count . ,(length (chat-code-child-changed-files child)))
       ,@(when reason
           `((reason . ,(chat-code-collaboration--bounded reason))))))))

(defun chat-code-collaboration--conflict (child changed reason)
  "Return and record a conflicted merge result for CHILD."
  (setf (chat-code-child-status child) 'conflicted
        (chat-code-child-error child) reason)
  (chat-code-collaboration--emit-merge
   'workspace-merge-conflicted child 'conflicted reason)
  (chat-code-merge-result-create
   :child-id (chat-code-child-id child) :status 'conflicted
   :changed-files changed :reason reason))

(defun chat-code-collaboration-merge (child &optional source-root)
  "Validate, merge and verify completed CHILD into SOURCE-ROOT.

Conflicts are returned as typed results before source bytes are changed."
  (let* ((session (chat-code-child-parent-session child))
         (root (chat-code-collaboration--root
                (or source-root (chat-session-working-directory session))))
         (base (chat-code-child-base-revision child))
         (expected (chat-code-child-changed-files child))
         (workspace (chat-code-child-workspace child))
         (workspace-available
          (and workspace
               (eq (chat-workspace-status workspace) 'active)
               (file-directory-p (chat-workspace-path workspace))))
         (changed (and workspace-available
                       (chat-code-collaboration-changed-files child))))
    (chat-code-collaboration--emit-merge
     'workspace-merge-started child 'running)
    (cond
     ((not (eq (chat-code-child-status child) 'completed))
      (chat-code-collaboration--conflict
       child changed "child is not completed"))
     ((not (equal
            base
            (string-trim
             (chat-code-collaboration--git root "rev-parse" "HEAD"))))
      (chat-code-collaboration--conflict
       child changed "source HEAD no longer matches child base revision"))
     ((not (and workspace-available
                (chat-workspace--registered-p workspace)))
      (chat-code-collaboration--conflict
       child changed "child worktree ownership is unavailable"))
     ((and expected (not (equal expected changed)))
      (chat-code-collaboration--conflict
       child changed "child worktree changed after completion evidence"))
     ((not (cl-every
            (lambda (path)
              (chat-code-collaboration--path-owned-p
               path (chat-code-child-allowed-paths child)))
            changed))
      (chat-code-collaboration--conflict
       child changed "child changed a path outside its ownership"))
     ((chat-code-collaboration--intersects-p
       changed (chat-code-collaboration--parent-changed-files root base))
      (chat-code-collaboration--conflict
       child changed "source checkout changed one of the child paths"))
     (t
      (condition-case err
          (let ((patch (chat-code-collaboration--patch child)))
            (chat-code-collaboration--apply-patch root patch t)
            (chat-code-collaboration--apply-patch root patch nil)
            (let* ((verification
                    (funcall chat-code-collaboration-verification-function
                             root changed (chat-session-id session)))
                   (verification-id (plist-get verification :id))
                   (status (plist-get verification :status)))
              (setf (chat-code-child-verification-id child) verification-id)
              (if (memq status '(passed not-run))
                  (progn
                    (setf (chat-code-child-status child) 'merged)
                    (chat-workspace-release
                     (chat-code-child-child-session child) t)
                    (chat-code-collaboration--emit-merge
                     'workspace-merge-completed child 'merged)
                    (chat-code-merge-result-create
                     :child-id (chat-code-child-id child) :status 'merged
                     :changed-files changed :verification-id verification-id))
                (setf (chat-code-child-status child) 'blocked
                      (chat-code-child-error child)
                      "post-merge verification did not pass")
                (chat-code-merge-result-create
                 :child-id (chat-code-child-id child) :status 'blocked
                 :changed-files changed :verification-id verification-id
                 :reason (chat-code-child-error child)))))
        (error
         (chat-code-collaboration--conflict
          child changed (error-message-string err))))))))

(defun chat-code-collaboration-get (id)
  "Return coding child ID."
  (gethash id chat-code-collaboration--children))

(provide 'chat-code-collaboration)
;;; chat-code-collaboration.el ends here
