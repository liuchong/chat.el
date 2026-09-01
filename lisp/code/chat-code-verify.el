;;; chat-code-verify.el --- Project verification and bounded repair -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;;; Commentary:

;; Verification is a typed projection over execution, task, and session event
;; facts.  This module plans deterministic argv-only checks, runs them in a
;; fixed order, and bounds repair retries without creating another durable
;; state store.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'chat-event)
(require 'chat-execution)
(require 'chat-task)

(defgroup chat-code-verify nil
  "Project-level verification for coding sessions."
  :group 'chat)

(defconst chat-code-verification-statuses
  '(passed failed cancelled timed-out not-run blocked)
  "Closed set of verification result states.")

(defconst chat-code-verification-kinds
  '(format diagnostics lint typecheck test build)
  "Verification kinds in their canonical execution order.")

(defcustom chat-code-verify-default-timeout-seconds 120
  "Default timeout for one verification step."
  :type 'integer
  :group 'chat-code-verify)

(defcustom chat-code-verify-default-max-output-bytes (* 256 1024)
  "Maximum output retained for one verification step."
  :type 'integer
  :group 'chat-code-verify)

(defcustom chat-code-verify-default-repair-limit 2
  "Default number of repair rounds, clamped to zero through three."
  :type '(integer :tag "Repair rounds")
  :group 'chat-code-verify)

(defcustom chat-code-verify-project-file ".chat-verification.json"
  "Declarative project verification configuration file."
  :type 'string
  :group 'chat-code-verify)

(defcustom chat-code-verify-profile-function nil
  "Optional function called with project root and changed files.
It may return a `chat-verification-profile' and has precedence over project
configuration and deterministic detection."
  :type '(choice (const nil) function)
  :group 'chat-code-verify)

(cl-defstruct
    (chat-verification-step
     (:constructor chat-verification-step-create
                   (&key id kind argv directory timeout-seconds
                         max-output-bytes trigger required-p approval-class)))
  "One bounded argv-only verification action."
  id kind argv directory timeout-seconds max-output-bytes trigger required-p
  approval-class)

(cl-defstruct
    (chat-verification-profile
     (:constructor chat-verification-profile-create
                   (&key id project-root source revision steps repair-limit)))
  "Resolved verification policy for one project revision."
  id project-root source revision steps repair-limit)

(cl-defstruct
    (chat-verification-step-result
     (:constructor chat-verification-step-result-create
                   (&key id step-id kind status started-at ended-at exit-code
                         output reason execution-id fingerprint classification)))
  "Bounded evidence from one verification action."
  id step-id kind status started-at ended-at exit-code output reason
  execution-id fingerprint classification)

(cl-defstruct
    (chat-code-verify-result
     (:constructor chat-code-verify-result--create
                   (&key id profile-id project-root source revision status
                         step-results preflight-fingerprints repair-round
                         stop-reason session-id turn-id task-id parent-task-id
                         checkpoint-id
                         changed-files created-at updated-at)))
  "Overall verification conclusion and trace identifiers."
  id profile-id project-root source revision status step-results
  preflight-fingerprints repair-round stop-reason session-id turn-id task-id
  parent-task-id checkpoint-id changed-files created-at updated-at)

(defvar chat-code-verify--results (make-hash-table :test 'equal)
  "Process-local cache of result projections; tasks remain authoritative.")

(defvar chat-code-verify--profiles (make-hash-table :test 'equal)
  "Process-local cache of resolved, reproducible verification profiles.")

(defvar chat-code-verify--profile-contexts (make-hash-table :test 'equal)
  "Process-local ownership metadata keyed by verification profile id.")

(defvar chat-code-verify--sequence 0)

(defvar chat-code-verify-executor #'chat-code-verify--execute-step
  "Function that executes a step and calls CALLBACK with a result plist.")

(defun chat-code-verification-status-p (status)
  "Return non-nil when STATUS is a public verification status."
  (memq status chat-code-verification-statuses))

(defun chat-code-verify-result-create (&rest arguments)
  "Create a verified result from keyword ARGUMENTS."
  (let ((result (apply #'chat-code-verify-result--create arguments)))
    (unless (chat-code-verification-status-p
             (chat-code-verify-result-status result))
      (error "Invalid verification status: %S"
             (chat-code-verify-result-status result)))
    result))

(defun chat-code-verify--now-ms ()
  "Return Unix time in milliseconds."
  (round (* 1000 (float-time))))

(defun chat-code-verify--new-id (prefix)
  "Return a process-unique identifier beginning with PREFIX."
  (format "%s-%d-%d" prefix (chat-code-verify--now-ms)
          (cl-incf chat-code-verify--sequence)))

(defun chat-code-verify--root (directory)
  "Return canonical project DIRECTORY with a trailing separator."
  (file-name-as-directory (file-truename (expand-file-name directory))))

(defun chat-code-verify--inside-root-p (path root)
  "Return non-nil when PATH is inside canonical ROOT."
  (file-in-directory-p (file-truename (expand-file-name path root)) root))

(defun chat-code-verify-validate-step (step &optional root)
  "Validate STEP and optional project ROOT, then return STEP."
  (unless (chat-verification-step-p step)
    (error "Not a verification step: %S" step))
  (unless (and (stringp (chat-verification-step-id step))
               (not (string-empty-p (chat-verification-step-id step))))
    (error "Verification step id must be non-empty text"))
  (unless (memq (chat-verification-step-kind step)
                chat-code-verification-kinds)
    (error "Invalid verification kind: %S"
           (chat-verification-step-kind step)))
  (unless (and (consp (chat-verification-step-argv step))
               (cl-every #'stringp (chat-verification-step-argv step)))
    (error "Verification command must be a nonempty argv list"))
  (unless (and (numberp (chat-verification-step-timeout-seconds step))
               (> (chat-verification-step-timeout-seconds step) 0))
    (error "Verification timeout must be positive"))
  (unless (and (integerp (chat-verification-step-max-output-bytes step))
               (> (chat-verification-step-max-output-bytes step) 0))
    (error "Verification output limit must be positive"))
  (when root
    (let ((directory (chat-code-verify--root
                      (or (chat-verification-step-directory step) root))))
      (unless (or (equal directory root)
                  (file-in-directory-p directory root))
        (error "Verification directory escapes project root: %s" directory))
      (setf (chat-verification-step-directory step) directory)))
  step)

(defun chat-code-verify-validate-profile (profile)
  "Validate and normalize PROFILE, then return it."
  (unless (chat-verification-profile-p profile)
    (error "Not a verification profile: %S" profile))
  (let ((root (chat-code-verify--root
               (chat-verification-profile-project-root profile)))
        (limit (or (chat-verification-profile-repair-limit profile)
                   chat-code-verify-default-repair-limit)))
    (unless (and (integerp limit) (<= 0 limit) (<= limit 3))
      (error "Repair limit must be between zero and three"))
    (setf (chat-verification-profile-project-root profile) root
          (chat-verification-profile-repair-limit profile) limit
          (chat-verification-profile-steps profile)
          (sort (copy-sequence (chat-verification-profile-steps profile))
                (lambda (left right)
                  (let ((left-kind
                         (cl-position (chat-verification-step-kind left)
                                      chat-code-verification-kinds))
                        (right-kind
                         (cl-position (chat-verification-step-kind right)
                                      chat-code-verification-kinds)))
                    (if (= left-kind right-kind)
                        (string< (chat-verification-step-id left)
                                 (chat-verification-step-id right))
                      (< left-kind right-kind))))))
    (let ((ids (mapcar #'chat-verification-step-id
                       (chat-verification-profile-steps profile))))
      (unless (= (length ids) (length (delete-dups (copy-sequence ids))))
        (error "Verification step ids must be unique")))
    (mapc (lambda (step) (chat-code-verify-validate-step step root))
          (chat-verification-profile-steps profile)))
  profile)

(defun chat-code-verify--read-small-file (path &optional limit)
  "Read at most LIMIT characters from PATH."
  (when (file-readable-p path)
    (with-temp-buffer
      (insert-file-contents path nil 0 (or limit 262144))
      (buffer-string))))

(defun chat-code-verify--step
    (root id kind argv &optional required trigger directory)
  "Create one detected step under ROOT."
  (chat-verification-step-create
   :id id :kind kind :argv argv
   :directory (expand-file-name (or directory ".") root)
   :timeout-seconds chat-code-verify-default-timeout-seconds
   :max-output-bytes chat-code-verify-default-max-output-bytes
   :trigger (or trigger 'changed) :required-p required
   :approval-class 'inspect))

(defun chat-code-verify--changed-with-extension (files extensions)
  "Return changed FILES whose extension occurs in EXTENSIONS."
  (seq-filter
   (lambda (path) (member (downcase (or (file-name-extension path) ""))
                          extensions))
   files))

(defun chat-code-verify--package-profile (root changed data)
  "Build a profile from package manifest DATA."
  (let* ((scripts (alist-get 'scripts data))
         (targeted
          (seq-filter
           (lambda (path)
             (string-match-p
              "\\(?:^\\|/\\)\\(?:test\\|tests\\)/\\|\\.\\(?:test\\|spec\\)\\."
              path))
           (chat-code-verify--changed-with-extension
            changed '("js" "jsx" "ts" "tsx"))))
         steps)
    (dolist (entry '((lint . lint) (typecheck . typecheck)
                     (test . test) (build . build)))
      (let* ((name (symbol-name (car entry)))
             (present (or (alist-get (car entry) scripts)
                          (alist-get name scripts nil nil #'string=))))
        (when present
          (push (chat-code-verify--step
                 root (concat "javascript-" name) (cdr entry)
                 (append (list "npm" "run" name)
                         (when (and (eq (cdr entry) 'test) targeted)
                           (append '("--") targeted)))
                 t)
                steps))))
    (nreverse steps)))

(defun chat-code-verify--python-profile (root changed manifest)
  "Build conservative Python steps from MANIFEST text."
  (let* ((python-files
          (chat-code-verify--changed-with-extension changed '("py")))
         (conventional-tests
          (directory-files root nil
                           "\\`test_.*\\.py\\'\\|_test\\.py\\'" t))
         (test-targets
          (or (seq-filter
               (lambda (path)
                 (string-match-p
                  "\\(?:^\\|/\\)test[^/]*\\.py\\|_test\\.py\\'" path))
               python-files)
              conventional-tests
              '(".")))
         (targets (or python-files '(".")))
        steps)
    (when (string-match-p "\\(?:tool\\.ruff\\|ruff\\)" manifest)
      (push (chat-code-verify--step
             root "python-lint" 'lint
             (append '("python3" "-m" "ruff" "check") targets) t)
            steps))
    (when (string-match-p "\\(?:tool\\.mypy\\|mypy\\)" manifest)
      (push (chat-code-verify--step
             root "python-typecheck" 'typecheck
             (append '("python3" "-m" "mypy") targets) t)
            steps))
    (when (or conventional-tests
              (file-exists-p (expand-file-name "pytest.ini" root))
              (string-match-p "pytest" manifest))
      (push (chat-code-verify--step
             root "python-test" 'test
             (if (or (file-exists-p (expand-file-name "pytest.ini" root))
                     (string-match-p "pytest" manifest))
                 (append '("python3" "-m" "pytest") test-targets)
               '("python3" "-m" "unittest"))
             t)
            steps))
    (nreverse steps)))

(defun chat-code-verify--javascript-convention-steps (root)
  "Return conservative JavaScript checks detected directly below ROOT."
  (seq-keep
   (lambda (name)
     (when (file-readable-p (expand-file-name name root))
       (chat-code-verify--step
        root (concat "javascript-test-" (file-name-extension name))
        'test (list "node" name) t)))
   '("test.js" "test.mjs" "test.cjs")))

(defun chat-code-verify--elisp-convention-steps (root)
  "Return one batch ERT check for top-level test files below ROOT."
  (when-let ((tests (directory-files root nil "-test\\.el\\'" t)))
    (list
     (chat-code-verify--step
      root "elisp-test" 'test
      (append '("emacs" "-Q" "--batch" "-L" ".")
              (apply #'append
                     (mapcar (lambda (path) (list "-l" path)) tests))
              '("--eval" "(ert-run-tests-batch-and-exit)"))
      t))))

(defun chat-code-verify--step-id-present-p (steps id)
  "Return non-nil when STEPS already contains ID."
  (seq-some (lambda (step)
              (equal (chat-verification-step-id step) id))
            steps))

(defun chat-code-verify--zig-profile (root)
  "Return Zig checks only when BUILD.ZIG declares a test step."
  (when-let* ((manifest
               (chat-code-verify--read-small-file
                (expand-file-name "build.zig" root))))
    (when (string-match-p "\\.step[[:space:]\n]*(\"test\"" manifest)
      (list (chat-code-verify--step
             root "zig-test" 'test '("zig" "build" "test") t)))))

(defun chat-code-verify--clojure-profile (root)
  "Return a Clojure check for an explicit Lein project."
  (when (file-readable-p (expand-file-name "project.clj" root))
    (list (chat-code-verify--step
           root "clojure-test" 'test '("lein" "test") t))))

(defun chat-code-verify--java-profile (root)
  "Return one offline Java project test when its build authority is clear."
  (let ((gradle-wrapper (expand-file-name "gradlew" root))
        (maven-wrapper (expand-file-name "mvnw" root)))
    (cond
     ((and (or (file-readable-p (expand-file-name "build.gradle" root))
               (file-readable-p (expand-file-name "build.gradle.kts" root)))
           (file-executable-p gradle-wrapper)
           (file-readable-p
            (expand-file-name "gradle/wrapper/gradle-wrapper.properties" root)))
      (list (chat-code-verify--step
             root "java-gradle-test" 'test
             (list gradle-wrapper "--offline" "test") t)))
     ((and (file-readable-p (expand-file-name "pom.xml" root))
           (file-executable-p maven-wrapper)
           (file-readable-p
            (expand-file-name ".mvn/wrapper/maven-wrapper.properties" root)))
      (list (chat-code-verify--step
             root "java-maven-test" 'test
             (list maven-wrapper "-o" "test") t)))
     ((file-readable-p (expand-file-name "pom.xml" root))
      (list (chat-code-verify--step
             root "java-maven-test" 'test '("mvn" "-o" "test") t))))))

(defun chat-code-verify--typescript-profile (root steps)
  "Return a TypeScript compiler check unless STEPS already type-check it."
  (when (and (file-readable-p (expand-file-name "tsconfig.json" root))
             (not (chat-code-verify--step-id-present-p
                   steps "javascript-typecheck")))
    (let ((local-compiler
           (expand-file-name "node_modules/.bin/tsc" root)))
      (list (chat-code-verify--step
             root "typescript-typecheck" 'typecheck
             (list (if (file-executable-p local-compiler)
                       local-compiler
                     "tsc")
                   "--noEmit" "--project" "tsconfig.json")
             t)))))

(defun chat-code-verify--make-test-profile (root)
  "Return `make test' only for an exact top-level test target.
This is the conservative project authority for C, C++, SQL and other
ecosystems without a universal language-level test command."
  (when-let* ((manifest
               (or (chat-code-verify--read-small-file
                    (expand-file-name "GNUmakefile" root))
                   (chat-code-verify--read-small-file
                    (expand-file-name "Makefile" root))
                   (chat-code-verify--read-small-file
                    (expand-file-name "makefile" root)))))
    (when (string-match-p "^test[[:space:]]*:" manifest)
      (list (chat-code-verify--step
             root "make-test" 'test '("make" "test") t)))))

(defun chat-code-verify--extended-language-steps (root steps)
  "Return conservative extended-language checks below ROOT.
STEPS prevents a manifest-declared TypeScript check from being duplicated."
  (append (chat-code-verify--zig-profile root)
          (chat-code-verify--clojure-profile root)
          (chat-code-verify--java-profile root)
          (chat-code-verify--typescript-profile root steps)
          (chat-code-verify--make-test-profile root)))

(defun chat-code-verify--detected-steps (root changed)
  "Return deterministic verification steps for ROOT and CHANGED files."
  (let (steps)
    (when (file-readable-p (expand-file-name "package.json" root))
      (let ((json-object-type 'alist)
            (json-array-type 'list))
        (setq steps
              (append
               steps
               (chat-code-verify--package-profile
                root changed
                (json-read-from-string
                 (chat-code-verify--read-small-file
                  (expand-file-name "package.json" root))))))))
    (unless (file-readable-p (expand-file-name "package.json" root))
      (setq steps
            (append steps
                    (chat-code-verify--javascript-convention-steps root))))
    (let ((python-manifest
           (or (chat-code-verify--read-small-file
                (expand-file-name "pyproject.toml" root))
               (and (file-readable-p (expand-file-name "pytest.ini" root))
                    "pytest")
               "")))
      (when (or (not (string-empty-p python-manifest))
                (directory-files root nil
                                 "\\`test_.*\\.py\\'\\|_test\\.py\\'" t))
        (setq steps
              (append steps
                      (chat-code-verify--python-profile
                       root changed python-manifest)))))
    (when (file-readable-p (expand-file-name "go.mod" root))
      (setq steps
            (append
             steps
             (list (chat-code-verify--step
                    root "go-test" 'test '("go" "test" "./...") t)
                   (chat-code-verify--step
                    root "go-build" 'build '("go" "build" "./...") t)))))
    (when (file-readable-p (expand-file-name "Cargo.toml" root))
      (setq steps
            (append
             steps
             (list (chat-code-verify--step
                    root "rust-format" 'format
                    '("cargo" "fmt" "--check") t)
                   (chat-code-verify--step
                    root "rust-test" 'test '("cargo" "test") t)
                   (chat-code-verify--step
                    root "rust-build" 'build '("cargo" "build") t)))))
    (setq steps
          (append steps (chat-code-verify--elisp-convention-steps root)))
    (setq steps
          (append steps
                  (chat-code-verify--extended-language-steps root steps)))
    (cond
     (steps steps)
     ((file-readable-p (expand-file-name "tests/run-tests.sh" root))
      (list (chat-code-verify--step
             root "project-test" 'test '("bash" "tests/run-tests.sh") t)))
     ((file-readable-p (expand-file-name "tests/run-tests.el" root))
      (list (chat-code-verify--step
             root "project-test" 'test
             '("emacs" "-Q" "--batch" "-L" "." "-L" "lisp"
               "-l" "tests/run-tests.el") t)))
     (t nil))))

(defun chat-code-verify--json-bool (value)
  "Return non-nil for JSON VALUE representing true."
  (and value (not (eq value :json-false)) (not (eq value :false))))

(defun chat-code-verify--profile-from-file (root)
  "Read a declarative verification profile below ROOT, or nil."
  (let ((path (expand-file-name chat-code-verify-project-file root)))
    (when (file-readable-p path)
      (let* ((data (json-parse-string
                    (chat-code-verify--read-small-file path)
                    :object-type 'alist :array-type 'list
                    :null-object nil :false-object :json-false))
             (steps
              (mapcar
               (lambda (entry)
                 (chat-verification-step-create
                  :id (alist-get 'id entry)
                  :kind (intern (alist-get 'kind entry))
                  :argv (append (alist-get 'argv entry) nil)
                  :directory (expand-file-name
                              (or (alist-get 'directory entry) ".") root)
                  :timeout-seconds
                  (or (alist-get 'timeoutSeconds entry)
                      chat-code-verify-default-timeout-seconds)
                  :max-output-bytes
                  (or (alist-get 'maxOutputBytes entry)
                      chat-code-verify-default-max-output-bytes)
                  :trigger (intern (or (alist-get 'trigger entry) "changed"))
                  :required-p (chat-code-verify--json-bool
                               (alist-get 'required entry))
                  :approval-class
                  (intern (or (alist-get 'approvalClass entry) "inspect"))))
               (alist-get 'steps data))))
        (chat-verification-profile-create
         :id (or (alist-get 'id data) "project") :project-root root
         :source 'project-config :revision (or (alist-get 'revision data) "1")
         :steps steps :repair-limit
         (or (alist-get 'repairLimit data)
             chat-code-verify-default-repair-limit))))))

(defun chat-code-verify-plan (project-root &optional changed-files context)
  "Resolve a verification profile for PROJECT-ROOT and CHANGED-FILES."
  (let* ((root (chat-code-verify--root project-root))
         (changed (sort (delete-dups (copy-sequence changed-files)) #'string<))
         (profile
          (or (and (functionp chat-code-verify-profile-function)
                   (funcall chat-code-verify-profile-function root changed))
              (chat-code-verify--profile-from-file root)
              (chat-verification-profile-create
               :id (chat-code-verify--new-id "verification-profile")
               :project-root root :source 'detected :revision "1"
               :steps (chat-code-verify--detected-steps root changed)
               :repair-limit chat-code-verify-default-repair-limit))))
    ;; A project profile id names configuration, while the provider needs an
    ;; opaque handle for this exact resolution.  Reusing the configured id here
    ;; lets concurrent sessions overwrite each other's cached profile.
    (setq profile (copy-chat-verification-profile profile))
    (setf (chat-verification-profile-id profile)
          (chat-code-verify--new-id "verification-profile"))
    (chat-code-verify-validate-profile profile)
    (puthash (chat-verification-profile-id profile)
             profile chat-code-verify--profiles)
    (puthash
     (chat-verification-profile-id profile)
     (list :session-id (plist-get context :session-id)
           :turn-id (plist-get context :turn-id)
           :task-id (plist-get context :task-id)
           :created-at (chat-code-verify--now-ms))
     chat-code-verify--profile-contexts)
    (chat-code-verify--emit
     'verification-planned context
     `((profile_id . ,(chat-verification-profile-id profile))
       (source . ,(symbol-name (chat-verification-profile-source profile)))
       (step_count . ,(length (chat-verification-profile-steps profile)))))
    profile))

(defun chat-code-verify-failure-fingerprint (kind exit-code output)
  "Return a stable digest for KIND, EXIT-CODE and bounded OUTPUT."
  (secure-hash
   'sha256
   (format "%s\0%s\0%s" kind exit-code
           (replace-regexp-in-string
            "[[:space:]]+" " "
            (string-trim (or output ""))))))

(defun chat-code-verify-classify-failure (fingerprint preflight)
  "Classify FINGERPRINT against PREFLIGHT fingerprints."
  (if (member fingerprint preflight) 'pre-existing 'introduced))

(defun chat-code-verify--bounded-output (output limit)
  "Return OUTPUT bounded to LIMIT bytes."
  (let ((text (or output "")))
    (if (<= (string-bytes text) limit)
        text
      (concat (truncate-string-to-width text (max 0 (- limit 18)) nil nil t)
              "\n... [truncated]"))))

(defun chat-code-verify--execute-step (step context callback)
  "Execute STEP using CONTEXT and invoke CALLBACK exactly once."
  (let* ((argv (chat-verification-step-argv step))
         (program (car argv))
         (limit (chat-verification-step-max-output-bytes step)))
    (if (not (executable-find program))
        (progn
          (funcall callback
                   (list :status 'blocked
                         :reason (format "command-not-found: %s" program)))
          nil)
      (let ((buffer (generate-new-buffer " *chat-verification*"))
            (done nil)
            (bytes 0)
            (output-limit-p nil)
            timer
            record)
        (cl-labels
            ((finish
              (status &optional exit-code reason)
              (unless done
                (setq done t)
                (when (timerp timer) (cancel-timer timer))
                (let ((output
                       (when (buffer-live-p buffer)
                         (with-current-buffer buffer (buffer-string)))))
                  (when (buffer-live-p buffer) (kill-buffer buffer))
                  (funcall callback
                           (list :status status :exit-code exit-code
                                 :reason reason
                                 :output (chat-code-verify--bounded-output
                                          output limit)
                                 :execution-id
                                 (and record
                                      (chat-execution-record-id record))))))))
          (condition-case err
              (progn
                (setq
                 record
                 (chat-execution-start
                 (chat-execution-request-from-context
                   argv
                   :backend (chat-execution-backend-for-policy 'build)
                   :directory (chat-verification-step-directory step)
                   :policy 'build
                   :read-roots (list (plist-get context :project-root))
                   :write-roots (list (plist-get context :project-root))
                   :network nil
                   :require-process-tree-cleanup t
                   :session-id (plist-get context :session-id)
                   :turn-id (plist-get context :turn-id)
                   :task-id (plist-get context :task-id)
                   :parent-id (plist-get context :parent-id)
                   :idempotency 'idempotent
                   :timeout (chat-verification-step-timeout-seconds step)
                   :metadata
                   `((kind . "verification")
                     (stepId . ,(chat-verification-step-id step))))
                  :name (format "chat-verify-%s"
                                (chat-verification-step-id step))
                  :buffer buffer
                  :filter
                  (lambda (process chunk)
                    (unless done
                      (cl-incf bytes (string-bytes chunk))
                      (when (buffer-live-p (process-buffer process))
                        (with-current-buffer (process-buffer process)
                          (goto-char (point-max))
                          (insert chunk)))
                      (when (> bytes limit)
                        (setq output-limit-p t)
                        (when record
                          (finish 'output-limit nil "output-limit")
                          (chat-execution-cancel
                           record "output limit exceeded")))))
                  :sentinel
                  (lambda (process _event)
                    (unless (process-live-p process)
                      (finish (cond
                               ((and record
                                     (eq (chat-execution-record-status record)
                                         'timed-out))
                                'timed-out)
                               ((zerop (process-exit-status process)) 'passed)
                               (t 'failed))
                              (process-exit-status process)
                              (unless (zerop (process-exit-status process))
                                "nonzero-exit"))))))
                (if output-limit-p
                    (progn
                      (finish 'output-limit nil "output-limit")
                      (chat-execution-cancel record "output limit exceeded"))
                  (setq timer
                        (run-at-time
                         (chat-verification-step-timeout-seconds step) nil
                         (lambda ()
                           (unless done
                             (finish 'timed-out nil "timeout")
                             (chat-execution-cancel
                              record "verification timeout"))))))
                (list :cancel
                      (lambda ()
                        (unless done
                          (finish 'cancelled nil "cancelled")
                          (chat-execution-cancel
                           record "verification cancelled")))))
            (error
             (finish 'blocked nil (error-message-string err))
             nil)))))))

(defun chat-code-verify--normalize-step-result (step raw preflight)
  "Turn executor RAW output for STEP into a typed result."
  (let* ((raw-status (plist-get raw :status))
         (status (pcase raw-status
                   ('passed 'passed)
                   ('cancelled 'cancelled)
                   ('timed-out 'timed-out)
                   ('blocked 'blocked)
                   (_ 'failed)))
         (output (chat-code-verify--bounded-output
                  (plist-get raw :output)
                  (chat-verification-step-max-output-bytes step)))
         (fingerprint
          (unless (eq status 'passed)
            (chat-code-verify-failure-fingerprint
             (chat-verification-step-kind step)
             (plist-get raw :exit-code) output))))
    (chat-verification-step-result-create
     :id (chat-code-verify--new-id "verification-step")
     :step-id (chat-verification-step-id step)
     :kind (chat-verification-step-kind step)
     :status status
     :started-at (plist-get raw :started-at)
     :ended-at (chat-code-verify--now-ms)
     :exit-code (plist-get raw :exit-code)
     :output output :reason (or (plist-get raw :reason)
                                (and (eq raw-status 'output-limit)
                                     "output-limit"))
     :execution-id (plist-get raw :execution-id)
     :fingerprint fingerprint
     :classification (and fingerprint
                          (chat-code-verify-classify-failure
                           fingerprint preflight)))))

(defun chat-code-verify--overall-status (profile step-results)
  "Return overall status for PROFILE and STEP-RESULTS."
  (if (null (chat-verification-profile-steps profile))
      'not-run
    (let ((required
           (seq-filter
            (lambda (result)
              (let ((step-id (chat-verification-step-result-step-id result)))
                (seq-some
                 (lambda (step)
                   (and (equal step-id (chat-verification-step-id step))
                        (chat-verification-step-required-p step)))
                 (chat-verification-profile-steps profile))))
            step-results)))
      (cond
       ((seq-some (lambda (item)
                    (eq (chat-verification-step-result-status item) 'cancelled))
                  required)
        'cancelled)
       ((seq-some (lambda (item)
                    (eq (chat-verification-step-result-status item) 'timed-out))
                  required)
        'timed-out)
       ((seq-some (lambda (item)
                    (eq (chat-verification-step-result-status item) 'blocked))
                  required)
        'blocked)
       ((or (< (length required)
               (cl-count-if #'chat-verification-step-required-p
                            (chat-verification-profile-steps profile)))
            (seq-some (lambda (item)
                        (not (eq (chat-verification-step-result-status item)
                                 'passed)))
                      required))
        'failed)
       (t 'passed)))))

(defun chat-code-verify--emit (type context payload)
  "Emit verification TYPE using CONTEXT and bounded PAYLOAD."
  (chat-event-emit
   type :session-id (plist-get context :session-id)
   :turn-id (plist-get context :turn-id)
   :task-id (plist-get context :task-id)
   :parent-id (plist-get context :parent-id)
   :source 'verification :payload payload))

(defun chat-code-verify--result-to-alist (result)
  "Return durable JSON-friendly projection of RESULT."
  `((id . ,(chat-code-verify-result-id result))
    (profileId . ,(chat-code-verify-result-profile-id result))
    (projectRoot . ,(chat-code-verify-result-project-root result))
    (source . ,(symbol-name (chat-code-verify-result-source result)))
    (revision . ,(chat-code-verify-result-revision result))
    (status . ,(symbol-name (chat-code-verify-result-status result)))
    (sessionId . ,(chat-code-verify-result-session-id result))
    (turnId . ,(chat-code-verify-result-turn-id result))
    (taskId . ,(chat-code-verify-result-task-id result))
    (parentTaskId . ,(chat-code-verify-result-parent-task-id result))
    (repairRound . ,(or (chat-code-verify-result-repair-round result) 0))
    (stopReason . ,(chat-code-verify-result-stop-reason result))
    (checkpointId . ,(chat-code-verify-result-checkpoint-id result))
    (changedFiles . ,(chat-code-verify-result-changed-files result))
    (steps .
           ,(mapcar
             (lambda (item)
               `((id . ,(chat-verification-step-result-id item))
                 (stepId . ,(chat-verification-step-result-step-id item))
                 (kind . ,(symbol-name
                            (chat-verification-step-result-kind item)))
                 (status . ,(symbol-name
                              (chat-verification-step-result-status item)))
                 (exitCode . ,(chat-verification-step-result-exit-code item))
                 (reason . ,(chat-verification-step-result-reason item))
                 (output . ,(chat-verification-step-result-output item))
                 (executionId .
                              ,(chat-verification-step-result-execution-id item))
                 (fingerprint .
                              ,(chat-verification-step-result-fingerprint item))
                 (classification .
                                 ,(and
                                   (chat-verification-step-result-classification
                                    item)
                                   (symbol-name
                                    (chat-verification-step-result-classification
                                     item))))))
             (chat-code-verify-result-step-results result)))))

(defun chat-code-verify--task-status (status)
  "Map verification STATUS to durable task state."
  (pcase status
    ((or 'passed 'not-run) 'completed)
    ('cancelled 'canceled)
    (_ 'failed)))

(defun chat-code-verify--finish-result (result task callback)
  "Persist RESULT through TASK and invoke CALLBACK."
  (setf (chat-code-verify-result-updated-at result) (chat-code-verify--now-ms))
  (puthash (chat-code-verify-result-id result) result chat-code-verify--results)
  (when task
    (chat-task-transition
     task (chat-code-verify--task-status
           (chat-code-verify-result-status result))
     :result (chat-code-verify--result-to-alist result)
     :error (unless (memq (chat-code-verify-result-status result)
                          '(passed not-run))
              (or (chat-code-verify-result-stop-reason result)
                  (symbol-name (chat-code-verify-result-status result))))))
  (chat-code-verify--emit
   'verification-completed
   (list :session-id (chat-code-verify-result-session-id result)
         :turn-id (chat-code-verify-result-turn-id result)
         :task-id (chat-code-verify-result-task-id result)
         :parent-id (chat-code-verify-result-parent-task-id result))
   `((verification_id . ,(chat-code-verify-result-id result))
     (status . ,(symbol-name (chat-code-verify-result-status result)))
     (step_count . ,(length (chat-code-verify-result-step-results result)))
     (repair_round . ,(or (chat-code-verify-result-repair-round result) 0))))
  (when callback (funcall callback result))
  result)

(cl-defun chat-code-verify-run
    (profile &key session-id turn-id task-id run-id parent-id checkpoint-id
             changed-files preflight-fingerprints on-complete)
  "Run PROFILE asynchronously and invoke ON-COMPLETE with its typed result.

TASK-ID identifies the calling Agent task.  Every verification run owns a
distinct durable task whose parent is TASK-ID, or PARENT-ID when TASK-ID is
absent."
  (chat-code-verify-validate-profile profile)
  (let* ((id (chat-code-verify--new-id "verification"))
         (verification-task-id id)
         (parent-task-id (or task-id parent-id))
         (context (list :session-id session-id :turn-id turn-id
                        :task-id verification-task-id :run-id run-id
                        :parent-id parent-task-id
                        :project-root
                        (chat-verification-profile-project-root profile)))
         (task
          (when (or session-id parent-task-id)
            (chat-task-adopt
             :id verification-task-id :parent-id parent-task-id
             :kind 'verification
             :title "Project verification" :status 'queued
             :session-id session-id :source 'verification
             :resources
             (list (list :key
                         (concat "workspace:"
                                 (chat-verification-profile-project-root profile))
                         :mode 'read))
             :payload
             `((profileId . ,(chat-verification-profile-id profile))
               (revision . ,(chat-verification-profile-revision profile)))
             :replace t)))
         (result
          (chat-code-verify-result-create
           :id id :profile-id (chat-verification-profile-id profile)
           :project-root (chat-verification-profile-project-root profile)
           :source (chat-verification-profile-source profile)
           :revision (chat-verification-profile-revision profile)
           :status (if (chat-verification-profile-steps profile)
                       'failed 'not-run)
           :step-results nil :preflight-fingerprints preflight-fingerprints
           :repair-round 0 :session-id session-id :turn-id turn-id
           :task-id verification-task-id :parent-task-id parent-task-id
           :checkpoint-id checkpoint-id
           :changed-files changed-files :created-at (chat-code-verify--now-ms)))
         (steps (copy-sequence (chat-verification-profile-steps profile)))
         results
         active)
    (when task (chat-task-transition task 'running))
    (puthash id result chat-code-verify--results)
    (cl-labels
        ((next
          ()
          (if-let ((step (pop steps)))
              (progn
                (chat-code-verify--emit
                 'verification-step-started context
                 `((verification_id . ,id)
                   (step_id . ,(chat-verification-step-id step))
                   (kind . ,(symbol-name (chat-verification-step-kind step)))))
                (setq
                 active
                 (funcall
                  chat-code-verify-executor step context
                  (lambda (raw)
                    (let ((item
                           (chat-code-verify--normalize-step-result
                            step raw preflight-fingerprints)))
                      (setq results (append results (list item)))
                      (chat-code-verify--emit
                       'verification-step-completed context
                       `((verification_id . ,id)
                         (step_id . ,(chat-verification-step-id step))
                         (status . ,(symbol-name
                                     (chat-verification-step-result-status
                                      item)))
                         (execution_id .
                                       ,(chat-verification-step-result-execution-id
                                         item))))
                      (next))))))
            (setf (chat-code-verify-result-step-results result) results
                  (chat-code-verify-result-status result)
                  (chat-code-verify--overall-status profile results))
            (chat-code-verify--finish-result result task on-complete))))
      (if steps
          (next)
        (chat-code-verify--finish-result result task on-complete)))
    (list :result result
          :cancel
          (lambda ()
            (when-let ((cancel (plist-get active :cancel)))
              (funcall cancel))))))

(defun chat-code-verify-run-sync (profile &optional context)
  "Run PROFILE to completion for batch commands and tests."
  (let (result)
    (apply #'chat-code-verify-run
           profile
           (append context (list :on-complete (lambda (value)
                                                (setq result value)))))
    (let ((deadline
           (+ (float-time)
              5
              (apply #'+ 0
                     (mapcar #'chat-verification-step-timeout-seconds
                             (chat-verification-profile-steps profile))))))
      (while (and (null result) (< (float-time) deadline))
        (accept-process-output nil 0.05)))
    (or result (error "Verification did not finish within its total budget"))))

(defun chat-code-verify--failure-fingerprints (result)
  "Return sorted failure fingerprints from RESULT."
  (sort
   (delq nil
         (mapcar #'chat-verification-step-result-fingerprint
                 (chat-code-verify-result-step-results result)))
   #'string<))

(defun chat-code-verify-feedback (result)
  "Return bounded, factual repair feedback for RESULT."
  (mapconcat
   (lambda (item)
     (format "%s (%s, exit %s): %s\n%s"
             (chat-verification-step-result-kind item)
             (chat-verification-step-result-status item)
             (or (chat-verification-step-result-exit-code item) "n/a")
             (or (chat-verification-step-result-reason item) "failed")
             (or (chat-verification-step-result-output item) "")))
   (seq-filter
    (lambda (item)
      (not (eq (chat-verification-step-result-status item) 'passed)))
    (chat-code-verify-result-step-results result))
   "\n\n"))

(defun chat-code-verify--allowed-repair-p (changed allowed)
  "Return non-nil when every CHANGED path is explicitly ALLOWED."
  (and changed
       (cl-every
        (lambda (path)
          (member (directory-file-name path)
                  (mapcar #'directory-file-name allowed)))
        changed)))

(cl-defun chat-code-verify-run-with-repair
    (profile repair-function
             &key allowed-paths rollback-function session-id turn-id task-id
             parent-id checkpoint-id changed-files preflight-fingerprints
             on-complete)
  "Run PROFILE and bounded REPAIR-FUNCTION retries.

REPAIR-FUNCTION receives feedback, one-based round and a completion callback.
Its callback must return :changed-files and :diff-digest.  Unowned changes call
ROLLBACK-FUNCTION and make the result blocked."
  (let ((round 0)
        (limit (chat-verification-profile-repair-limit profile))
        previous-failures
        previous-diff
        run
        finish)
    (setq
     finish
     (lambda (result &optional reason status)
       (when reason
         (setf (chat-code-verify-result-stop-reason result) reason))
       (when status
         (setf (chat-code-verify-result-status result) status))
       (setf (chat-code-verify-result-repair-round result) round)
       (chat-code-verify--emit
        'repair-stopped
        (list :session-id session-id :turn-id turn-id
              :task-id (chat-code-verify-result-task-id result)
              :parent-id (chat-code-verify-result-parent-task-id result))
        `((verification_id . ,(chat-code-verify-result-id result))
          (round . ,round) (reason . ,reason)
          (status . ,(symbol-name (chat-code-verify-result-status result)))))
       (when on-complete (funcall on-complete result))))
    (setq
     run
     (lambda (active-profile)
       (chat-code-verify-run
        active-profile :session-id session-id :turn-id turn-id
        :task-id task-id :parent-id parent-id :checkpoint-id checkpoint-id
        :changed-files changed-files
        :preflight-fingerprints preflight-fingerprints
        :on-complete
        (lambda (result)
          (let ((failures (chat-code-verify--failure-fingerprints result)))
            (cond
             ((eq (chat-code-verify-result-status result) 'passed)
              (funcall finish result))
             ((not (eq (chat-code-verify-result-status result) 'failed))
              (funcall finish result))
             ((and previous-failures (equal failures previous-failures))
              (funcall finish result "unchanged-failure" 'failed))
             ((>= round limit)
              (funcall finish result "repair-budget-exhausted" 'failed))
             (t
              (setq previous-failures failures)
              (cl-incf round)
              (chat-code-verify--emit
               'repair-started
               (list :session-id session-id :turn-id turn-id
                     :task-id (chat-code-verify-result-task-id result)
                     :parent-id
                     (chat-code-verify-result-parent-task-id result))
               `((verification_id . ,(chat-code-verify-result-id result))
                 (round . ,round)))
              (funcall
               repair-function (chat-code-verify-feedback result) round
               (lambda (repair)
                 (let ((changed (plist-get repair :changed-files))
                       (digest (plist-get repair :diff-digest)))
                   (cond
                    ((not (chat-code-verify--allowed-repair-p
                           changed allowed-paths))
                     (when rollback-function (funcall rollback-function))
                     (funcall finish result
                              "repair-outside-allowed-paths" 'blocked))
                    ((or (null digest) (equal digest previous-diff))
                     (funcall finish result
                              "repair-produced-no-new-diff" 'failed))
                    (t
                     (setq previous-diff digest)
                     (let* ((failed-ids
                             (mapcar
                              #'chat-verification-step-result-step-id
                              (seq-remove
                               (lambda (item)
                                 (eq (chat-verification-step-result-status item)
                                     'passed))
                               (chat-code-verify-result-step-results result))))
                            (rerun
                             (seq-filter
                              (lambda (step)
                                (or (chat-verification-step-required-p step)
                                    (member (chat-verification-step-id step)
                                            failed-ids)))
                              (chat-verification-profile-steps profile))))
                       (funcall
                        run
                        (chat-verification-profile-create
                         :id (chat-verification-profile-id profile)
                         :project-root
                         (chat-verification-profile-project-root profile)
                         :source (chat-verification-profile-source profile)
                         :revision (chat-verification-profile-revision profile)
                         :steps rerun :repair-limit limit)))))))))))))))
    (funcall run profile)))

(defun chat-code-verify--symbol (value)
  "Return VALUE as a symbol when possible."
  (cond ((symbolp value) value)
        ((stringp value) (intern value))
        (t nil)))

(defun chat-code-verify--result-from-task (task)
  "Rebuild a typed verification projection from durable TASK."
  (when-let* ((data (chat-task-result task))
              (id (alist-get 'id data)))
    (let ((result
           (chat-code-verify-result-create
            :id id :profile-id (alist-get 'profileId data)
            :project-root (alist-get 'projectRoot data)
            :source (chat-code-verify--symbol (alist-get 'source data))
            :revision (alist-get 'revision data)
            :status (chat-code-verify--symbol (alist-get 'status data))
            :repair-round (or (alist-get 'repairRound data) 0)
            :stop-reason (alist-get 'stopReason data)
            :checkpoint-id (alist-get 'checkpointId data)
            :changed-files (alist-get 'changedFiles data)
            :session-id (or (alist-get 'sessionId data)
                            (chat-task-session-id task))
            :turn-id (alist-get 'turnId data)
            :task-id (or (alist-get 'taskId data) (chat-task-id task))
            :parent-task-id (or (alist-get 'parentTaskId data)
                                (chat-task-parent-id task))
            :created-at 0 :updated-at 0
            :step-results
            (mapcar
             (lambda (item)
               (chat-verification-step-result-create
                :id (alist-get 'id item)
                :step-id (alist-get 'stepId item)
                :kind (chat-code-verify--symbol (alist-get 'kind item))
                :status (chat-code-verify--symbol (alist-get 'status item))
                :exit-code (alist-get 'exitCode item)
                :reason (alist-get 'reason item)
                :output (alist-get 'output item)
                :execution-id (alist-get 'executionId item)
                :fingerprint (alist-get 'fingerprint item)
                :classification
                (chat-code-verify--symbol (alist-get 'classification item))))
             (alist-get 'steps data)))))
      (puthash id result chat-code-verify--results)
      result)))

(defun chat-code-verify-get (id)
  "Return verification result ID from cache or durable task state."
  (or (gethash id chat-code-verify--results)
      (when-let* ((task (chat-task-get id)))
        (chat-code-verify--result-from-task task))
      (seq-some
       (lambda (task)
         (when (eq (chat-task-kind task) 'verification)
           (let ((result (chat-code-verify--result-from-task task)))
             (and result (equal id (chat-code-verify-result-id result))
                  result))))
       (chat-task-list))))

(defun chat-code-verify-list ()
  "Return cached and durable results in deterministic creation order."
  (dolist (task (chat-task-list))
    (when (and (eq (chat-task-kind task) 'verification)
               (chat-task-result task))
      (chat-code-verify--result-from-task task)))
  (let (results)
    (maphash (lambda (_id result) (push result results))
             chat-code-verify--results)
    (sort results
          (lambda (left right)
            (< (chat-code-verify-result-created-at left)
               (chat-code-verify-result-created-at right))))))

(defun chat-code-verify-latest-for-session (session-id &optional turn-id)
  "Return the newest live verification for SESSION-ID and optional TURN-ID.

This lookup is used while completing an agent turn, so it deliberately avoids
loading durable tasks from disk.  Restart-safe inspection remains available
through `chat-code-verify-get' and `chat-code-verify-list'."
  (let (matches)
    (maphash
     (lambda (_id result)
       (when (and (equal session-id
                         (chat-code-verify-result-session-id result))
                  (or (null turn-id)
                      (equal turn-id
                             (chat-code-verify-result-turn-id result))))
         (push result matches)))
     chat-code-verify--results)
    (car
     (sort matches
           (lambda (left right)
             (> (chat-code-verify-result-created-at left)
                (chat-code-verify-result-created-at right)))))))

(defun chat-code-verify--context-owned-p
    (context session-id &optional task-id)
  "Return non-nil when CONTEXT belongs to SESSION-ID and optional TASK-ID."
  (and context
       (equal session-id (plist-get context :session-id))
       (or (null task-id)
           (equal task-id (plist-get context :task-id)))))

(defun chat-code-verify-profile-owned-p (profile-id session-id &optional task-id)
  "Return non-nil when PROFILE-ID belongs to SESSION-ID and optional TASK-ID."
  (chat-code-verify--context-owned-p
   (gethash profile-id chat-code-verify--profile-contexts)
   session-id task-id))

(defun chat-code-verify-latest-profile-for-context
    (session-id &optional task-id)
  "Return the newest live profile owned by SESSION-ID and optional TASK-ID."
  (let (matches)
    (maphash
     (lambda (id context)
       (when (chat-code-verify--context-owned-p context session-id task-id)
         (when-let* ((profile (gethash id chat-code-verify--profiles)))
           (push (cons profile (or (plist-get context :created-at) 0))
                 matches))))
     chat-code-verify--profile-contexts)
    (caar (sort matches (lambda (left right) (> (cdr left) (cdr right)))))))

(defun chat-code-verify-result-owned-p (result session-id &optional task-id)
  "Return non-nil when RESULT belongs to SESSION-ID and optional Agent TASK-ID."
  (and result
       (equal session-id (chat-code-verify-result-session-id result))
       (or (null task-id)
           (equal task-id
                  (chat-code-verify-result-parent-task-id result)))))

(defun chat-code-verify-latest-result-for-context
    (session-id &optional task-id)
  "Return the newest live result owned by SESSION-ID and optional Agent TASK-ID."
  (let (matches)
    (maphash
     (lambda (_id result)
       (when (chat-code-verify-result-owned-p result session-id task-id)
         (push result matches)))
     chat-code-verify--results)
    (car
     (sort matches
           (lambda (left right)
             (> (or (chat-code-verify-result-created-at left) 0)
                (or (chat-code-verify-result-created-at right) 0)))))))

(defun chat-code-verify-summary (result)
  "Return final-response facts projected only from RESULT evidence."
  (let* ((steps (chat-code-verify-result-step-results result))
         (passed (cl-count 'passed steps
                           :key #'chat-verification-step-result-status)))
    (format "Verification: %s (%d/%d steps passed)%s"
            (chat-code-verify-result-status result) passed (length steps)
            (if-let ((reason (chat-code-verify-result-stop-reason result)))
                (format "; %s" reason)
              ""))))

(defun chat-code-verify-get-profile (id)
  "Return cached verification profile ID, or nil."
  (gethash id chat-code-verify--profiles))

(defun chat-code-verify-result-data (result)
  "Return the durable public data projection for RESULT."
  (chat-code-verify--result-to-alist result))

(defun chat-code-verify-profile-to-alist (profile)
  "Return JSON-friendly PROFILE data for tools and diagnostics."
  `((id . ,(chat-verification-profile-id profile))
    (projectRoot . ,(chat-verification-profile-project-root profile))
    (source . ,(symbol-name (chat-verification-profile-source profile)))
    (revision . ,(chat-verification-profile-revision profile))
    (repairLimit . ,(chat-verification-profile-repair-limit profile))
    (steps .
           ,(mapcar
             (lambda (step)
               `((id . ,(chat-verification-step-id step))
                 (kind . ,(symbol-name (chat-verification-step-kind step)))
                 (argv . ,(chat-verification-step-argv step))
                 (directory . ,(chat-verification-step-directory step))
                 (timeoutSeconds .
                                 ,(chat-verification-step-timeout-seconds step))
                 (maxOutputBytes .
                                 ,(chat-verification-step-max-output-bytes step))
                 (required . ,(and (chat-verification-step-required-p step) t))))
             (chat-verification-profile-steps profile)))))

(provide 'chat-code-verify)
;;; chat-code-verify.el ends here
