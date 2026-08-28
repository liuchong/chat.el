;;; chat-coding-eval.el --- Isolated coding task evaluations -*- lexical-binding: t; -*-

;;; Commentary:

;; Versioned coding tasks run in disposable workspaces.  Executors are
;; asynchronous; deterministic judges never call a model.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'chat-eval)
(require 'chat-llm)
(require 'chat-session)
(require 'chat-agent)
(require 'chat-model-capabilities)

(defconst chat-coding-eval-schema-version 1)

(defconst chat-coding-eval-fixture-generator-schema-version 1)

(defconst chat-coding-eval--indexed-source-pattern
  "\\.\\(?:el\\|py\\|js\\|mjs\\|cjs\\|ts\\|tsx\\|go\\|rs\\)\\'"
  "Source extensions used by the fixed coding Eval corpus.")

(defcustom chat-coding-eval-workspace-directory
  (expand-file-name "coding-eval/" temporary-file-directory)
  "Parent directory for disposable coding evaluation workspaces."
  :type 'directory :group 'chat)

(defcustom chat-coding-eval-clean-workspaces t
  "Whether terminal coding evaluations remove their workspaces."
  :type 'boolean :group 'chat)

(defcustom chat-coding-eval-max-fixture-files 12000
  "Maximum number of files accepted in one evaluation fixture."
  :type 'integer :group 'chat)

(defcustom chat-coding-eval-max-fixture-bytes (* 10 1024 1024)
  "Maximum aggregate bytes accepted in one evaluation fixture."
  :type 'integer :group 'chat)

(defcustom chat-coding-eval-max-command-output-bytes (* 64 1024)
  "Maximum command-judge output retained in a result check."
  :type 'integer :group 'chat)

(defcustom chat-coding-eval-approval-mode 'guarded
  "Approval mode used by the built-in live Agent executor."
  :type '(choice (const manual) (const guarded) (const dangerous))
  :group 'chat)

(defcustom chat-coding-eval-default-manifest
  (let* ((module (or load-file-name buffer-file-name))
         (root (and module
                    (expand-file-name "../../" (file-name-directory module))))
         (candidate (and root
                         (expand-file-name
                          "tests/fixtures/coding-eval/manifest.json" root))))
    (and candidate (file-exists-p candidate) candidate))
  "Default coding evaluation manifest for development checkouts."
  :type '(choice (const nil) file) :group 'chat)

(cl-defstruct (chat-coding-eval-task
               (:constructor chat-coding-eval-task-create-record))
  schema-version id revision category language description fixture-id
  fixture-directory prompt allowed-paths timeout-seconds judges tags
  fixture-generator fixture-generator-digest)

(cl-defstruct (chat-coding-eval-run-state
               (:constructor chat-coding-eval-run-state-create-record))
  task fixture-digest fixture-revision workspace workspace-id baseline
  fixture-file-count fixture-indexed-file-count
  started-at setup-duration-ms agent-duration-ms judge-started-at
  judge-duration-ms answer metadata
  changed-files out-of-scope-files checks executor-cancel process timer
  on-complete cleanup-p done-p)

(cl-defstruct (chat-coding-eval-suite-state
               (:constructor chat-coding-eval-suite-state-create-record))
  pending current results executor on-result on-complete cleanup-p cancelled-p)

(defun chat-coding-eval--json-value (object key)
  "Return KEY from JSON alist OBJECT."
  (alist-get key object))

(defun chat-coding-eval--safe-relative-path-p (path)
  "Return non-nil when PATH is a normalized relative path."
  (and (stringp path)
       (not (string-empty-p path))
       (not (file-name-absolute-p path))
       (not (string-prefix-p "~" path))
       (not (member ".." (split-string path "/" t)))
       (equal path (directory-file-name (file-name-unquote path)))))

(defun chat-coding-eval--read-generator (relative manifest-directory)
  "Read and validate generator RELATIVE to MANIFEST-DIRECTORY."
  (when relative
    (unless (chat-coding-eval--safe-relative-path-p relative)
      (error "Coding evaluation fixture generator path is unsafe"))
    (let* ((root (file-name-as-directory (file-truename manifest-directory)))
           (file (expand-file-name relative root)))
      (unless (and (file-regular-p file)
                   (not (file-symlink-p file))
                   (string-prefix-p root (file-truename file)))
        (error "Coding evaluation fixture generator does not exist: %s"
               relative))
      (let* ((json-object-type 'alist)
             (json-array-type 'list)
             (json-key-type 'symbol)
             (generator (json-read-file file)))
        (chat-coding-eval--validate-generator generator)
        (cons generator (chat-coding-eval--file-digest file))))))

(defun chat-coding-eval--validate-generator (generator)
  "Validate deterministic fixture GENERATOR and return it."
  (let ((version (alist-get 'schemaVersion generator))
        (kind (alist-get 'kind generator))
        (count (alist-get 'generatedFiles generator))
        (path-template (alist-get 'pathTemplate generator))
        (content-template (alist-get 'contentTemplate generator))
        (bucket-size (or (alist-get 'bucketSize generator) 100)))
    (unless (= (or version 0)
               chat-coding-eval-fixture-generator-schema-version)
      (error "Unsupported coding evaluation fixture generator schema"))
    (unless (equal kind "source-tree")
      (error "Unsupported coding evaluation fixture generator kind: %s" kind))
    (unless (and (integerp count) (> count 0)
                 (<= count chat-coding-eval-max-fixture-files))
      (error "Coding evaluation generated file count is invalid"))
    (unless (and (integerp bucket-size) (> bucket-size 0))
      (error "Coding evaluation generator bucket size is invalid"))
    (unless (and (stringp path-template)
                 (string-match-p (regexp-quote "{{index}}") path-template))
      (error "Coding evaluation generator path requires {{index}}"))
    (unless (and (stringp content-template)
                 (<= (string-bytes content-template) 4096))
      (error "Coding evaluation generator content is invalid"))
    generator))

(defun chat-coding-eval--render-generator-template
    (template index bucket-size)
  "Render TEMPLATE for INDEX grouped by BUCKET-SIZE."
  (let ((rendered
         (replace-regexp-in-string
          (regexp-quote "{{index}}") (number-to-string index)
          template t t)))
    (replace-regexp-in-string
     (regexp-quote "{{bucket}}")
     (number-to-string (/ index bucket-size)) rendered t t)))

(defun chat-coding-eval--materialize-generator (task workspace)
  "Materialize TASK's deterministic fixture generator in WORKSPACE."
  (when-let* ((generator (chat-coding-eval-task-fixture-generator task)))
    (let ((count (alist-get 'generatedFiles generator))
          (path-template (alist-get 'pathTemplate generator))
          (content-template (alist-get 'contentTemplate generator))
          (bucket-size (or (alist-get 'bucketSize generator) 100)))
      (dotimes (index count)
        (let* ((relative
                (chat-coding-eval--render-generator-template
                 path-template index bucket-size))
               (content
                (chat-coding-eval--render-generator-template
                 content-template index bucket-size))
               (file (expand-file-name relative workspace)))
          (unless (chat-coding-eval--safe-relative-path-p relative)
            (error "Generated fixture path is unsafe: %s" relative))
          (when (file-exists-p file)
            (error "Generated fixture path collides with base fixture: %s"
                   relative))
          (make-directory (file-name-directory file) t)
          (write-region content nil file nil 'silent))))))

(defun chat-coding-eval-task-declared-file-count (task)
  "Return the deterministic declared fixture file count for TASK."
  (+ (length (chat-coding-eval--fixture-files
              (chat-coding-eval-task-fixture-directory task)))
     (or (alist-get 'generatedFiles
                    (chat-coding-eval-task-fixture-generator task))
         0)))

(defun chat-coding-eval-task-declared-indexed-file-count (task)
  "Return the declared indexed source-file count for TASK."
  (+ (cl-count-if
      (lambda (file)
        (string-match-p chat-coding-eval--indexed-source-pattern file))
      (chat-coding-eval--fixture-files
       (chat-coding-eval-task-fixture-directory task)))
     (let* ((generator (chat-coding-eval-task-fixture-generator task))
            (count (or (alist-get 'generatedFiles generator) 0))
            (path-template (alist-get 'pathTemplate generator)))
       (if (and path-template
                (string-match-p chat-coding-eval--indexed-source-pattern
                                path-template))
           count
         0))))

(defun chat-coding-eval--validate-judge (judge)
  "Validate one task JUDGE and return it."
  (let ((type (chat-coding-eval--json-value judge 'type))
        (name (chat-coding-eval--json-value judge 'name)))
    (unless (member type '("answer-regexp" "file-regexp"
                           "file-not-regexp" "no-change" "command"))
      (error "Unsupported coding evaluation judge: %s" type))
    (unless (and (stringp name) (not (string-empty-p name)))
      (error "Coding evaluation judge name cannot be empty"))
    (when (member type '("answer-regexp" "file-regexp" "file-not-regexp"))
      (unless (stringp (chat-coding-eval--json-value judge 'regexp))
        (error "Judge %s requires regexp" name)))
    (when (member type '("file-regexp" "file-not-regexp"))
      (unless (chat-coding-eval--safe-relative-path-p
               (chat-coding-eval--json-value judge 'path))
        (error "Judge %s has an unsafe path" name)))
    (when (equal type "command")
      (let ((command (chat-coding-eval--json-value judge 'command)))
        (unless (and (listp command) command (seq-every-p #'stringp command))
          (error "Judge %s requires a nonempty argv command" name))))
    judge))

(defun chat-coding-eval--validate-task (task)
  "Validate TASK and return it."
  (unless (chat-coding-eval-task-p task)
    (error "Not a coding evaluation task"))
  (unless (= (or (chat-coding-eval-task-schema-version task) 0)
             chat-coding-eval-schema-version)
    (error "Unsupported coding evaluation task schema"))
  (dolist (field (list (chat-coding-eval-task-id task)
                       (chat-coding-eval-task-category task)
                       (chat-coding-eval-task-language task)
                       (chat-coding-eval-task-fixture-id task)
                       (chat-coding-eval-task-prompt task)))
    (unless (and (stringp field) (not (string-empty-p field)))
      (error "Coding evaluation task identity fields cannot be empty")))
  (unless (and (integerp (chat-coding-eval-task-revision task))
               (> (chat-coding-eval-task-revision task) 0))
    (error "Coding evaluation task revision must be positive"))
  (unless (file-directory-p (chat-coding-eval-task-fixture-directory task))
    (error "Coding evaluation fixture does not exist: %s"
           (chat-coding-eval-task-fixture-directory task)))
  (unless (and (listp (chat-coding-eval-task-allowed-paths task))
               (chat-coding-eval-task-allowed-paths task)
               (seq-every-p #'chat-coding-eval--safe-relative-path-p
                            (chat-coding-eval-task-allowed-paths task)))
    (error "Coding evaluation task requires safe allowed paths"))
  (unless (and (numberp (chat-coding-eval-task-timeout-seconds task))
               (> (chat-coding-eval-task-timeout-seconds task) 0))
    (error "Coding evaluation task timeout must be positive"))
  (unless (and (listp (chat-coding-eval-task-judges task))
               (chat-coding-eval-task-judges task))
    (error "Coding evaluation task requires judges"))
  (unless (and (listp (chat-coding-eval-task-tags task))
               (seq-every-p #'stringp (chat-coding-eval-task-tags task)))
    (error "Coding evaluation task tags must be strings"))
  (when (member "large-repo" (chat-coding-eval-task-tags task))
    (unless (>= (chat-coding-eval-task-declared-indexed-file-count task) 10000)
      (error "Large-repo coding evaluation fixture requires 10,000 indexed files")))
  (mapc #'chat-coding-eval--validate-judge
        (chat-coding-eval-task-judges task))
  task)

(defun chat-coding-eval--task-from-json (data manifest-directory)
  "Decode task DATA relative to MANIFEST-DIRECTORY."
  (let ((generator
         (chat-coding-eval--read-generator
          (chat-coding-eval--json-value data 'fixtureGenerator)
          manifest-directory)))
    (chat-coding-eval--validate-task
     (chat-coding-eval-task-create-record
    :schema-version (or (chat-coding-eval--json-value data 'schemaVersion)
                        chat-coding-eval-schema-version)
    :id (chat-coding-eval--json-value data 'id)
    :revision (or (chat-coding-eval--json-value data 'revision) 1)
    :category (chat-coding-eval--json-value data 'category)
    :language (chat-coding-eval--json-value data 'language)
    :description (chat-coding-eval--json-value data 'description)
    :fixture-id (chat-coding-eval--json-value data 'fixtureId)
    :fixture-directory
    (expand-file-name (chat-coding-eval--json-value data 'fixture)
                      manifest-directory)
    :prompt (chat-coding-eval--json-value data 'prompt)
    :allowed-paths (chat-coding-eval--json-value data 'allowedPaths)
    :timeout-seconds (or (chat-coding-eval--json-value data 'timeoutSeconds)
                         120)
      :judges (chat-coding-eval--json-value data 'judges)
      :tags (or (chat-coding-eval--json-value data 'tags) nil)
      :fixture-generator (car generator)
      :fixture-generator-digest (cdr generator)))))

(defun chat-coding-eval-load-suite (manifest)
  "Load, validate and return tasks from JSON MANIFEST."
  (let* ((json-object-type 'alist)
         (json-array-type 'list)
         (json-key-type 'symbol)
         (data (json-read-file manifest))
         (version (or (alist-get 'schemaVersion data) 0))
         (directory (file-name-directory (expand-file-name manifest)))
         tasks
         (seen (make-hash-table :test 'equal)))
    (unless (= version chat-coding-eval-schema-version)
      (error "Unsupported coding evaluation manifest schema: %s" version))
    (dolist (entry (alist-get 'tasks data))
      (let ((task (chat-coding-eval--task-from-json entry directory)))
        (when (gethash (chat-coding-eval-task-id task) seen)
          (error "Duplicate coding evaluation task: %s"
                 (chat-coding-eval-task-id task)))
        (puthash (chat-coding-eval-task-id task) t seen)
        (push task tasks)))
    (unless tasks
      (error "Coding evaluation manifest contains no tasks"))
    (sort tasks (lambda (left right)
                  (string< (chat-coding-eval-task-id left)
                           (chat-coding-eval-task-id right))))))

(defun chat-coding-eval-suite-coverage (tasks)
  "Return category and language counts for TASKS."
  (let ((categories (make-hash-table :test 'equal))
        (languages (make-hash-table :test 'equal))
        (tags (make-hash-table :test 'equal)))
    (dolist (task tasks)
      (puthash (chat-coding-eval-task-category task)
               (1+ (gethash (chat-coding-eval-task-category task)
                            categories 0))
               categories)
      (puthash (chat-coding-eval-task-language task)
               (1+ (gethash (chat-coding-eval-task-language task)
                            languages 0))
               languages)
      (dolist (tag (chat-coding-eval-task-tags task))
        (puthash tag (1+ (gethash tag tags 0)) tags)))
    `((taskCount . ,(length tasks))
      (categories . ,(let (items)
                       (maphash (lambda (key value)
                                  (push (cons key value) items))
                                categories)
                       (sort items (lambda (left right)
                                     (string< (car left) (car right))))))
      (languages . ,(let (items)
                      (maphash (lambda (key value)
                                 (push (cons key value) items))
                               languages)
                      (sort items (lambda (left right)
                                    (string< (car left) (car right))))))
      (tags . ,(let (items)
                 (maphash (lambda (key value)
                            (push (cons key value) items))
                          tags)
                 (sort items (lambda (left right)
                               (string< (car left) (car right)))))))))

(defun chat-coding-eval--fixture-files (directory)
  "Return validated regular files below DIRECTORY in stable order."
  (let ((files (directory-files-recursively directory "." nil t nil)))
    (when (> (length files) chat-coding-eval-max-fixture-files)
      (error "Coding evaluation fixture has too many files"))
    (dolist (file files)
      (when (file-symlink-p file)
        (error "Coding evaluation fixtures cannot contain symlinks: %s" file)))
    files))

(defun chat-coding-eval--snapshot-descend-p (directory)
  "Return non-nil when snapshot traversal may enter DIRECTORY."
  (not (equal ".git" (file-name-nondirectory (directory-file-name directory)))))

(defun chat-coding-eval-fixture-digest (directory)
  "Return a stable content digest for fixture DIRECTORY."
  (let ((files (chat-coding-eval--fixture-files directory))
        (total 0))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (dolist (file files)
        (let ((size (file-attribute-size (file-attributes file))))
          (setq total (+ total size))
          (when (> total chat-coding-eval-max-fixture-bytes)
            (error "Coding evaluation fixture is too large")))
        (insert (encode-coding-string (file-relative-name file directory)
                                      'utf-8))
        (insert "\0")
        (insert-file-contents-literally file)
        (insert "\0"))
      (secure-hash 'sha256 (current-buffer)))))

(defun chat-coding-eval--file-digest (file)
  "Return a stable digest for FILE, including symlink targets."
  (if-let ((target (file-symlink-p file)))
      (secure-hash 'sha256 (concat "symlink:" target))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally file)
      (secure-hash 'sha256 (current-buffer)))))

(defun chat-coding-eval--snapshot (directory)
  "Return a relative-file digest snapshot of DIRECTORY."
  (let (snapshot)
    (dolist (file (directory-files-recursively
                   directory "." nil #'chat-coding-eval--snapshot-descend-p nil))
      (push (cons (file-relative-name file directory)
                  (chat-coding-eval--file-digest file))
            snapshot))
    (sort snapshot (lambda (left right) (string< (car left) (car right))))))

(defun chat-coding-eval--git (workspace &rest argv)
  "Run Git ARGV in WORKSPACE and return trimmed output or signal."
  (let ((default-directory (file-name-as-directory workspace))
        (process-environment
         (append '("GIT_CONFIG_NOSYSTEM=1" "GIT_TERMINAL_PROMPT=0")
                 process-environment)))
    (with-temp-buffer
      (let ((status (apply #'process-file "git" nil t nil argv)))
        (unless (zerop status)
          (error "Git setup failed (%s): %s" status (string-trim (buffer-string))))
        (string-trim (buffer-string))))))

(defun chat-coding-eval--initialize-repository (workspace)
  "Initialize WORKSPACE as a fixed Git baseline and return its revision."
  (chat-coding-eval--git workspace "init" "--quiet")
  (chat-coding-eval--git workspace "add" "--all")
  (chat-coding-eval--git
   workspace "-c" "user.name=chat-eval" "-c"
   "user.email=chat-eval@invalid" "commit" "--quiet" "-m" "fixture baseline")
  (chat-coding-eval--git workspace "rev-parse" "HEAD"))

(defun chat-coding-eval--changed-files (before after)
  "Return sorted paths that differ between snapshots BEFORE and AFTER."
  (let ((paths (delete-dups (append (mapcar #'car before)
                                    (mapcar #'car after))))
        changed)
    (dolist (path paths)
      (unless (equal (cdr (assoc path before)) (cdr (assoc path after)))
        (push path changed)))
    (sort changed #'string<)))

(defun chat-coding-eval--allowed-path-p (path allowed-paths)
  "Return non-nil when PATH is covered by ALLOWED-PATHS."
  (seq-some
   (lambda (allowed)
     (or (equal path allowed)
         (string-prefix-p (file-name-as-directory allowed) path)))
   allowed-paths))

(defun chat-coding-eval--bounded-output (text)
  "Return TEXT bounded for command evidence."
  (if (<= (string-bytes text) chat-coding-eval-max-command-output-bytes)
      text
    (truncate-string-to-width text chat-coding-eval-max-command-output-bytes
                              nil nil t)))

(defun chat-coding-eval--read-judge-file (state judge)
  "Read JUDGE's safe path from STATE."
  (let* ((relative (alist-get 'path judge))
         (root (file-name-as-directory
                (file-truename (chat-coding-eval-run-state-workspace state))))
         (file (expand-file-name relative root)))
    (unless (and (string-prefix-p root file)
                 (not (file-symlink-p file)))
      (error "Judge path escaped evaluation workspace"))
    (if (file-regular-p file)
        (let ((resolved (file-truename file)))
          (unless (string-prefix-p root resolved)
            (error "Judge path escaped evaluation workspace"))
          (with-temp-buffer
            (insert-file-contents file nil 0 chat-coding-eval-max-fixture-bytes)
            (buffer-string)))
      nil)))

(defun chat-coding-eval--sync-judge (state judge)
  "Evaluate non-command JUDGE for STATE and return a check."
  (let* ((type (alist-get 'type judge))
         (name (alist-get 'name judge))
         (regexp (alist-get 'regexp judge)))
    (pcase type
      ("answer-regexp"
       (let ((actual (or (chat-coding-eval-run-state-answer state) "")))
         (chat-eval-check name (and (stringp actual)
                                    (string-match-p regexp actual))
                          regexp actual)))
      ("file-regexp"
       (let ((actual (chat-coding-eval--read-judge-file state judge)))
         (chat-eval-check name (and actual (string-match-p regexp actual))
                          regexp actual)))
      ("file-not-regexp"
       (let ((actual (chat-coding-eval--read-judge-file state judge)))
         (chat-eval-check name (and actual
                                    (not (string-match-p regexp actual)))
                          (concat "not " regexp) actual)))
      ("no-change"
       (let ((actual (chat-coding-eval-run-state-changed-files state)))
         (chat-eval-check name (null actual) nil actual)))
      (_ (error "Not a synchronous coding evaluation judge: %s" type)))))

(defun chat-coding-eval--cancel-timer (state)
  "Cancel STATE's active timeout timer."
  (when (timerp (chat-coding-eval-run-state-timer state))
    (cancel-timer (chat-coding-eval-run-state-timer state)))
  (setf (chat-coding-eval-run-state-timer state) nil))

(defun chat-coding-eval--cleanup (state)
  "Clean STATE workspace and return non-nil on success."
  (let ((workspace (chat-coding-eval-run-state-workspace state)))
    (condition-case nil
        (progn
          (when (and (chat-coding-eval-run-state-cleanup-p state)
                     workspace (file-directory-p workspace))
            (delete-directory workspace t))
          (or (not (chat-coding-eval-run-state-cleanup-p state))
              (not (file-exists-p workspace))))
      (error nil))))

(defun chat-coding-eval--finish (state status &optional detail)
  "Finish STATE once with STATUS and optional DETAIL."
  (unless (chat-coding-eval-run-state-done-p state)
    (setf (chat-coding-eval-run-state-done-p state) t)
    (chat-coding-eval--cancel-timer state)
    (when-let ((process (chat-coding-eval-run-state-process state)))
      (when (process-live-p process)
        (delete-process process)))
    (let* ((cleanup-ok (chat-coding-eval--cleanup state))
           (task (chat-coding-eval-run-state-task state))
           (finished (funcall chat-eval-clock-function))
           (checks (append
                    (chat-coding-eval-run-state-checks state)
                    (list (chat-eval-check
                           "workspace-cleanup" cleanup-ok t cleanup-ok detail))))
           (result
            (chat-eval-record-result
             :scenario-id (concat "coding/" (chat-coding-eval-task-id task))
             :scenario-revision (chat-coding-eval-task-revision task)
             :category (concat "coding/"
                               (chat-coding-eval-task-category task))
             :fixture-id (chat-coding-eval-task-fixture-id task)
             :fixture-digest (chat-coding-eval-run-state-fixture-digest state)
             :started-at (chat-coding-eval-run-state-started-at state)
             :finished-at finished
             :status status
             :checks checks
             :metadata
             `((taskId . ,(chat-coding-eval-task-id task))
               (language . ,(chat-coding-eval-task-language task))
               (taskTags . ,(chat-coding-eval-task-tags task))
               (fixtureFileCount .
                                 ,(chat-coding-eval-run-state-fixture-file-count
                                   state))
               (fixtureIndexedFileCount .
                                        ,(chat-coding-eval-run-state-fixture-indexed-file-count
                                          state))
               (fixtureGeneratorDigest .
                                       ,(chat-coding-eval-task-fixture-generator-digest
                                         task))
               (fixtureRevision .
                                ,(chat-coding-eval-run-state-fixture-revision
                                  state))
               (workspaceId .
                            ,(chat-coding-eval-run-state-workspace-id state))
               (phaseDurationMs .
                                ((setup .
                                        ,(chat-coding-eval-run-state-setup-duration-ms
                                          state))
                                 (agent .
                                        ,(chat-coding-eval-run-state-agent-duration-ms
                                          state))
                                 (judge .
                                        ,(chat-coding-eval-run-state-judge-duration-ms
                                          state))))
               (changedFiles . ,(chat-coding-eval-run-state-changed-files state))
               (outOfScopeFiles .
                                ,(chat-coding-eval-run-state-out-of-scope-files
                                  state))
               (timeoutSeconds .
                               ,(chat-coding-eval-task-timeout-seconds task))
               (workspaceCleaned . ,cleanup-ok)
               (executor . ,(chat-coding-eval-run-state-metadata state))))))
      (when-let ((callback (chat-coding-eval-run-state-on-complete state)))
        (funcall callback result state))
      result)))

(defun chat-coding-eval--start-command-judge (state judge remaining)
  "Start command JUDGE for STATE, then continue with REMAINING."
  (let* ((buffer (generate-new-buffer " *chat-coding-eval-judge*"))
         (default-directory
          (file-name-as-directory (chat-coding-eval-run-state-workspace state)))
         (process
          (make-process
           :name (format "chat-coding-eval-%s"
                         (chat-coding-eval-task-id
                          (chat-coding-eval-run-state-task state)))
           :buffer buffer
           :stderr buffer
           :command (alist-get 'command judge)
           :connection-type 'pipe
           :noquery t
           :sentinel
           (lambda (process _event)
             (when (memq (process-status process) '(exit signal))
               (unless (process-get process 'chat-coding-eval-timeout)
                 (chat-coding-eval--cancel-timer state)
                 (let* ((output-buffer (process-buffer process))
                        (output (if (buffer-live-p output-buffer)
                                    (with-current-buffer output-buffer
                                      (buffer-string))
                                  ""))
                        (exit-code (process-exit-status process))
                        (expected (or (alist-get 'expectedExit judge) 0))
                        (passed (= expected exit-code)))
                   (when (buffer-live-p output-buffer)
                     (kill-buffer output-buffer))
                   (setf (chat-coding-eval-run-state-process state) nil
                         (chat-coding-eval-run-state-checks state)
                         (append
                          (chat-coding-eval-run-state-checks state)
                          (list
                           (chat-eval-check
                            (alist-get 'name judge) passed expected
                            `((exitCode . ,exit-code)
                              (command . ,(alist-get 'command judge))
                              (output .
                                      ,(chat-coding-eval--bounded-output output)))))))
                   (chat-coding-eval--run-judges state remaining))))))))
    (setf (chat-coding-eval-run-state-process state) process
          (chat-coding-eval-run-state-timer state)
          (run-at-time
           (or (alist-get 'timeoutSeconds judge) 30) nil
           (lambda ()
             (unless (chat-coding-eval-run-state-done-p state)
               (process-put process 'chat-coding-eval-timeout t)
               (when (process-live-p process) (delete-process process))
               (let ((output-buffer (process-buffer process)))
                 (when (buffer-live-p output-buffer)
                   (kill-buffer output-buffer)))
               (setf (chat-coding-eval-run-state-process state) nil
                     (chat-coding-eval-run-state-checks state)
                     (append
                      (chat-coding-eval-run-state-checks state)
                      (list (chat-eval-check
                             (alist-get 'name judge) nil
                             (or (alist-get 'expectedExit judge) 0)
                             'timed-out
                             "Command judge timed out."))))
               (chat-coding-eval--finish
                state 'timed-out "Command judge timeout")))))))

(defun chat-coding-eval--run-judges (state judges)
  "Run JUDGES sequentially for STATE."
  (unless (chat-coding-eval-run-state-judge-started-at state)
    (setf (chat-coding-eval-run-state-judge-started-at state)
          (funcall chat-eval-clock-function)))
  (if (null judges)
      (progn
        (setf (chat-coding-eval-run-state-judge-duration-ms state)
              (max 0 (- (funcall chat-eval-clock-function)
                        (chat-coding-eval-run-state-judge-started-at state))))
        (chat-coding-eval--finish
         state
         (if (seq-every-p #'chat-eval-check-passed
                          (chat-coding-eval-run-state-checks state))
             'passed
           'failed)))
    (let ((judge (car judges)))
      (if (equal (alist-get 'type judge) "command")
          (chat-coding-eval--start-command-judge state judge (cdr judges))
        (setf (chat-coding-eval-run-state-checks state)
              (append (chat-coding-eval-run-state-checks state)
                      (list (chat-coding-eval--sync-judge state judge))))
        (chat-coding-eval--run-judges state (cdr judges))))))

(defun chat-coding-eval--executor-finished (state status answer metadata)
  "Handle executor STATUS, ANSWER and METADATA for STATE."
  (unless (chat-coding-eval-run-state-done-p state)
    (chat-coding-eval--cancel-timer state)
    (setf (chat-coding-eval-run-state-answer state) answer
          (chat-coding-eval-run-state-metadata state) metadata
          (chat-coding-eval-run-state-agent-duration-ms state)
          (max 0 (- (funcall chat-eval-clock-function)
                    (chat-coding-eval-run-state-started-at state)
                    (or (chat-coding-eval-run-state-setup-duration-ms state)
                        0))))
    (let* ((task (chat-coding-eval-run-state-task state))
           (changed
            (chat-coding-eval--changed-files
             (chat-coding-eval-run-state-baseline state)
             (chat-coding-eval--snapshot
              (chat-coding-eval-run-state-workspace state))))
           (out-of-scope
            (seq-remove
             (lambda (path)
               (chat-coding-eval--allowed-path-p
                path (chat-coding-eval-task-allowed-paths task)))
             changed)))
      (setf (chat-coding-eval-run-state-changed-files state) changed
            (chat-coding-eval-run-state-out-of-scope-files state) out-of-scope
            (chat-coding-eval-run-state-checks state)
            (list
             (chat-eval-check "executor-status" (eq status 'completed)
                              'completed status)
             (chat-eval-check "allowed-paths" (null out-of-scope)
                              nil out-of-scope)))
      (cond
       ((eq status 'cancelled)
        (chat-coding-eval--finish state 'cancelled))
       ((not (eq status 'completed))
        (chat-coding-eval--finish state 'error))
       (out-of-scope
        (chat-coding-eval--finish state 'failed
                                  "Executor changed out-of-scope files"))
       (t
        (chat-coding-eval--run-judges
         state (chat-coding-eval-task-judges task)))))))

(defun chat-coding-eval-cancel (state)
  "Cancel coding evaluation STATE and return non-nil once."
  (unless (chat-coding-eval-run-state-done-p state)
    (when-let ((cancel (chat-coding-eval-run-state-executor-cancel state)))
      (ignore-errors (funcall cancel)))
    (chat-coding-eval--finish state 'cancelled "Evaluation cancelled")
    t))

(cl-defun chat-coding-eval-run
    (task executor &key on-complete (cleanup chat-coding-eval-clean-workspaces))
  "Run TASK with asynchronous EXECUTOR in a disposable workspace.

EXECUTOR is called with TASK, workspace and a completion callback accepting
STATUS, ANSWER and METADATA.  It may return a zero-argument cancellation
function.  ON-COMPLETE receives the immutable result and run state."
  (chat-coding-eval--validate-task task)
  (unless (functionp executor)
    (error "Coding evaluation executor must be callable"))
  (make-directory chat-coding-eval-workspace-directory t)
  (let* ((started (funcall chat-eval-clock-function))
         (workspace
          (make-temp-name
           (expand-file-name
            (concat (chat-coding-eval-task-id task) "-")
            chat-coding-eval-workspace-directory)))
         (state
          (chat-coding-eval-run-state-create-record
           :task task :fixture-digest "unavailable"
           :workspace workspace :workspace-id (file-name-nondirectory workspace)
           :started-at started :checks nil :on-complete on-complete
           :cleanup-p cleanup)))
    (condition-case setup-error
        (progn
          (copy-directory (chat-coding-eval-task-fixture-directory task)
                          workspace nil nil t)
          (chat-coding-eval--materialize-generator task workspace)
          (let ((fixture-files (chat-coding-eval--fixture-files workspace)))
            (setf (chat-coding-eval-run-state-fixture-file-count state)
                  (length fixture-files)
                  (chat-coding-eval-run-state-fixture-indexed-file-count state)
                  (cl-count-if
                   (lambda (file)
                     (string-match-p chat-coding-eval--indexed-source-pattern
                                     file))
                   fixture-files)
                  (chat-coding-eval-run-state-fixture-digest state)
                  (chat-coding-eval-fixture-digest workspace)))
          (setf (chat-coding-eval-run-state-fixture-revision state)
                (chat-coding-eval--initialize-repository workspace)
                (chat-coding-eval-run-state-baseline state)
                (chat-coding-eval--snapshot workspace)
                (chat-coding-eval-run-state-setup-duration-ms state)
                (max 0 (- (funcall chat-eval-clock-function) started)))
          (setf
           (chat-coding-eval-run-state-timer state)
           (run-at-time
            (chat-coding-eval-task-timeout-seconds task) nil
            (lambda ()
              (unless (chat-coding-eval-run-state-done-p state)
                (when-let ((cancel
                            (chat-coding-eval-run-state-executor-cancel state)))
                  (ignore-errors (funcall cancel)))
                (setf (chat-coding-eval-run-state-checks state)
                      (list (chat-eval-check "executor-status" nil
                                             'completed 'timed-out)))
                (chat-coding-eval--finish state 'timed-out
                                          "Evaluation task timeout")))))
          (condition-case executor-error
              (setf (chat-coding-eval-run-state-executor-cancel state)
                    (funcall
                     executor task workspace
                     (lambda (status answer metadata)
                       (chat-coding-eval--executor-finished
                        state status answer metadata))))
            (error
             (setf (chat-coding-eval-run-state-checks state)
                   (list (chat-eval-check
                          "executor-status" nil 'completed 'error
                          (error-message-string executor-error))))
             (chat-coding-eval--finish state 'error))))
      (error
       (setf (chat-coding-eval-run-state-setup-duration-ms state)
             (max 0 (- (funcall chat-eval-clock-function) started))
             (chat-coding-eval-run-state-checks state)
             (list (chat-eval-check "fixture-setup" nil "completed" "error"
                                    (error-message-string setup-error))))
       (chat-coding-eval--finish state 'error)))
    state))

(defun chat-coding-eval--suite-next (state)
  "Start the next pending task in suite STATE."
  (cond
   ((chat-coding-eval-suite-state-cancelled-p state)
    (setf (chat-coding-eval-suite-state-current state) nil)
    (when-let ((callback (chat-coding-eval-suite-state-on-complete state)))
      (funcall callback (nreverse (chat-coding-eval-suite-state-results state))
               state)))
   ((null (chat-coding-eval-suite-state-pending state))
    (setf (chat-coding-eval-suite-state-current state) nil)
    (when-let ((callback (chat-coding-eval-suite-state-on-complete state)))
      (funcall callback (nreverse (chat-coding-eval-suite-state-results state))
               state)))
   (t
    (let* ((entry (pop (chat-coding-eval-suite-state-pending state)))
           (repetition (car entry))
           (task (cdr entry))
           (executor (chat-coding-eval-suite-state-executor state)))
      (setf
       (chat-coding-eval-suite-state-current state)
       (chat-coding-eval-run
        task
        (lambda (current workspace done)
          (funcall
           executor current workspace
           (lambda (status answer metadata)
             (funcall done status answer
                      (cons (cons 'repetition repetition) metadata)))))
        :cleanup (chat-coding-eval-suite-state-cleanup-p state)
        :on-complete
        (lambda (result _run)
          (push result (chat-coding-eval-suite-state-results state))
          (when-let ((callback (chat-coding-eval-suite-state-on-result state)))
            (funcall callback result repetition state))
          ;; Break synchronous executor recursion and keep long suites
          ;; responsive between isolated tasks.
          (run-at-time 0 nil #'chat-coding-eval--suite-next state)))))))
  state)

(cl-defun chat-coding-eval-run-suite
    (tasks executor &key (repetitions 1) on-result on-complete
           (cleanup chat-coding-eval-clean-workspaces))
  "Run TASKS sequentially with EXECUTOR for REPETITIONS.

ON-RESULT receives each result, its one-based repetition and suite state.
ON-COMPLETE receives results in execution order and the suite state."
  (unless (and (listp tasks) tasks
               (seq-every-p #'chat-coding-eval-task-p tasks))
    (error "Coding evaluation suite requires tasks"))
  (unless (and (integerp repetitions) (> repetitions 0))
    (error "Coding evaluation repetitions must be positive"))
  (let (pending)
    (dotimes (index repetitions)
      (dolist (task tasks)
        (push (cons (1+ index) task) pending)))
    (let ((state
           (chat-coding-eval-suite-state-create-record
            :pending (nreverse pending)
            :results nil :executor executor
            :on-result on-result :on-complete on-complete
            :cleanup-p cleanup)))
      (chat-coding-eval--suite-next state))))

(defun chat-coding-eval-cancel-suite (state)
  "Cancel suite STATE and its current run."
  (unless (chat-coding-eval-suite-state-cancelled-p state)
    (setf (chat-coding-eval-suite-state-cancelled-p state) t
          (chat-coding-eval-suite-state-pending state) nil)
    (if-let ((current (chat-coding-eval-suite-state-current state)))
        (chat-coding-eval-cancel current)
      (chat-coding-eval--suite-next state))
    t))

(defun chat-coding-eval--capability-snapshot (provider)
  "Return bounded resolved capability facts for PROVIDER."
  (let ((facts (chat-model-capabilities-resolve provider)))
    `((schemaVersion . ,(chat-model-capabilities-schema-version facts))
      (provider . ,(symbol-name provider))
      (source . ,(symbol-name (chat-model-capabilities-source facts)))
      (stream . ,(chat-model-capabilities-stream facts))
      (tools . ,(chat-model-capabilities-tools facts))
      (toolChoice . ,(chat-model-capabilities-tool-choice facts))
      (reasoning . ,(chat-model-capabilities-reasoning facts))
      (structuredOutput .
                        ,(chat-model-capabilities-structured-output facts))
      (contextWindow . ,(chat-model-capabilities-context-window facts))
      (maxOutputTokens .
                       ,(chat-model-capabilities-max-output-tokens facts)))))

(defun chat-coding-eval--model-name (provider requested)
  "Resolve REQUESTED model name for PROVIDER."
  (or requested
      (plist-get (chat-llm-get-provider-config provider) :model)
      (user-error "Provider %s has no configured model" provider)))

(defun chat-coding-eval-agent-executor (provider &optional model-name)
  "Return a live Agent executor using PROVIDER and MODEL-NAME."
  (let ((resolved-model (chat-coding-eval--model-name provider model-name)))
    (lambda (task workspace done)
      (let* ((session
            (chat-session-create
             (format "Evaluation: %s" (chat-coding-eval-task-id task))
             provider resolved-model))
           (prompt
            (format
             (concat "%s\n\nWork only inside the current workspace. "
                     "The only paths you may change are: %s. "
                     "Finish with a concise answer describing the result.")
             (chat-coding-eval-task-prompt task)
             (string-join (chat-coding-eval-task-allowed-paths task) ", ")))
           (capabilities (chat-coding-eval--capability-snapshot provider))
           usage
           (tool-errors 0)
           (approvals 0)
           (stale-writes 0)
           run)
      (chat-session-set-working-directory session workspace)
      (setf (chat-session-approval-mode session) chat-coding-eval-approval-mode)
      (setq
       run
       (chat-agent-start
        (list
         :model provider
         :messages
         (list (make-chat-message
                :id (chat-session-new-message-id "coding-eval")
                :role :user :content prompt :timestamp (current-time)))
         :session session
         :profile 'code
         :project-root workspace
         :track-task t
         :task-title (chat-coding-eval-task-id task)
         :task-kind 'evaluation
         :transport 'stream
         :on-event
         (lambda (event)
           (when (plist-member event :usage)
             (setq usage (plist-get event :usage)))
           (pcase (plist-get event :type)
             ((or 'tool-error 'execution-error) (cl-incf tool-errors))
             ((or 'approval-requested 'approval-decided) (cl-incf approvals))
             ('stale-file (cl-incf stale-writes)))
           (when (eq (plist-get event :type) 'agent-end)
             (funcall
              done
              (plist-get event :status)
              (or (plist-get event :content) "")
              `((provider . ,(symbol-name provider))
                (model . ,resolved-model)
                (modelCapabilitySnapshot . ,capabilities)
                (profile . "code")
                (transport . "stream")
                (approvalMode . ,(symbol-name chat-coding-eval-approval-mode))
                (tokenUsage . ,usage)
                (sessionId . ,(chat-session-id session))
                (runtimeTaskId . ,(and run
                                        (chat-agent-run-state-task-id run)))
                (workspaceId . ,(file-name-nondirectory
                                 (directory-file-name workspace)))
                (checkpointId . nil)
                (traceId . nil)
                (steps . ,(plist-get event :steps))
                (toolCallCount . ,(length (plist-get event :tool-calls)))
                (toolResultCount . ,(length (plist-get event :tool-results)))
                (toolErrorCount . ,tool-errors)
                (approvalCount . ,approvals)
                (staleWriteCount . ,stale-writes)
                (verificationRetryCount . 0))))))))
        (lambda () (chat-agent-cancel run))))))

(defun chat-coding-eval-run-live
    (provider repetitions &optional manifest model-name)
  "Run the coding suite with PROVIDER for REPETITIONS.

MODEL-NAME defaults to PROVIDER's registered model."
  (interactive
   (let* ((provider
           (intern (read-string "Evaluation provider: "
                                (symbol-name chat-default-model))))
          (default-model (chat-coding-eval--model-name provider nil)))
     (list provider
           (read-number "Repetitions: " 3)
           chat-coding-eval-default-manifest
           (read-string "Model name: " default-model))))
  (let ((file (or manifest chat-coding-eval-default-manifest)))
    (unless (and file (file-exists-p file))
      (user-error "No coding evaluation manifest is available"))
    (unless (chat-llm-provider-configured-p provider)
      (user-error "Evaluation provider is not configured: %s" provider))
    (chat-coding-eval-run-suite
     (chat-coding-eval-load-suite file)
     (chat-coding-eval-agent-executor provider model-name)
     :repetitions repetitions
     :on-result
     (lambda (result repetition _state)
       (message "Coding eval %s repeat %d: %s"
                (chat-eval-result-scenario-id result) repetition
                (chat-eval-result-status result)))
     :on-complete
     (lambda (results _state)
       (message "Coding evaluation completed: %d result(s)" (length results))))))

(provide 'chat-coding-eval)
;;; chat-coding-eval.el ends here
