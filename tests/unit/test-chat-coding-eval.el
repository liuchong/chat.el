;;; test-chat-coding-eval.el --- Coding evaluation tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'test-helper)
(require 'chat-coding-eval)

(let ((previous (getenv "CHAT_CAMPAIGN_RUNNER_LIBRARY_ONLY")))
  (unwind-protect
      (progn
        (setenv "CHAT_CAMPAIGN_RUNNER_LIBRARY_ONLY" "1")
        (load (expand-file-name "tests/live/run-coding-campaign.el"
                                chat-test-root-dir)
              nil t))
    (setenv "CHAT_CAMPAIGN_RUNNER_LIBRARY_ONLY" previous)))

(defconst chat-coding-eval-test-manifest
  (expand-file-name "coding-eval/manifest.json" chat-test-fixtures-dir))

(defconst chat-coding-eval-test-extended-manifest
  (expand-file-name "coding-eval/manifest-extended.json"
                    chat-test-fixtures-dir))

(defconst chat-coding-eval-test-extended-mutation-smoke-manifest
  (expand-file-name "coding-eval/manifest-extended-mutation-smoke.json"
                    chat-test-fixtures-dir))

(defconst chat-coding-eval-test-focused-mutation-smoke-manifests
  '(("zig" "manifest-zig-mutation-smoke.json" ("zig"))
    ("clojure" "manifest-clojure-mutation-smoke.json" ("lein"))
    ("java" "manifest-java-mutation-smoke.json" ("java" "javac"))
    ("typescript" "manifest-typescript-mutation-smoke.json" ("node" "tsc"))
    ("c" "manifest-c-mutation-smoke.json" ("clang"))
    ("cpp" "manifest-cpp-mutation-smoke.json" ("clang++"))
    ("sql" "manifest-sql-mutation-smoke.json" ("sqlite3"))))

(defconst chat-coding-eval-test-large-repo-manifest
  (expand-file-name "coding-eval/manifest-large-repo.json"
                    chat-test-fixtures-dir))

(defconst chat-coding-eval-test-core-reliability-smoke-manifest
  (expand-file-name "coding-eval/manifest-core-reliability-smoke.json"
                    chat-test-fixtures-dir))

(defconst chat-coding-eval-test-go-refactor-diagnostic-manifest
  (expand-file-name "coding-eval/manifest-go-refactor-diagnostic.json"
                    chat-test-fixtures-dir))

(defconst chat-coding-eval-test-javascript-refactor-diagnostic-manifest
  (expand-file-name "coding-eval/manifest-javascript-refactor-diagnostic.json"
                    chat-test-fixtures-dir))

(defconst chat-coding-eval-test-rust-multi-file-diagnostic-manifest
  (expand-file-name "coding-eval/manifest-rust-multi-file-diagnostic.json"
                    chat-test-fixtures-dir))

(defconst chat-coding-eval-test-language-registry
  (expand-file-name "coding-eval/language-registry.json"
                    chat-test-fixtures-dir))

(defun chat-coding-eval-test--read-json (path)
  "Read PATH as an alist with lists for JSON arrays."
  (with-temp-buffer
    (insert-file-contents path)
    (let ((json-object-type 'alist)
          (json-array-type 'list)
          (json-key-type 'symbol))
      (json-read))))

(ert-deftest chat-coding-eval-agent-snapshot-preserves-live-run-progress ()
  "A timeout snapshot reports work accumulated before `agent-end'."
  (chat-coding-eval-test-with-runtime
   (let* ((task
           (chat-coding-eval-task-create-record
            :id "snapshot-progress"
            :prompt "Inspect and fix the sample."
            :allowed-paths '("sample.c")))
          (workspace (expand-file-name "workspace/" temp-dir))
          (chat-coding-eval-agent-config-function
           (lambda (_provider _model config) config))
          handle)
     (make-directory workspace t)
     (cl-letf (((symbol-function 'chat-code-enable) #'ignore)
               ((symbol-function 'chat-coding-eval--capability-snapshot)
                (lambda (_provider _model) '((schemaVersion . 2))))
               ((symbol-function 'chat-agent-start)
                (lambda (config)
                  (funcall
                   (plist-get (plist-get config :request-options)
                              :event-observer)
                   (chat-model-event-make
                    'started 'deepseek "deepseek-v4-flash"
                    "request-snapshot" 1))
                  (chat-agent--run-create
                   :provider 'deepseek
                   :model "deepseek-v4-flash"
                   :task-id "agent-task-snapshot"
                   :step 7
                   :tool-calls '((:id "call-1") (:id "call-2"))
                   :tool-results '("result-1" "result-2")))))
       (setq handle
             (funcall
              (chat-coding-eval-agent-executor
               'deepseek "deepseek-v4-flash")
              task workspace #'ignore)))
     (let* ((snapshot
             (funcall (chat-coding-eval-executor-handle-snapshot handle)))
            (metadata (plist-get snapshot :metadata)))
       (should (= 7 (alist-get 'steps metadata)))
       (should (= 2 (alist-get 'toolCallCount metadata)))
       (should (= 2 (alist-get 'toolResultCount metadata)))
       (should (equal "evaluation terminated before agent-end"
                      (alist-get 'failureReason metadata)))))))

(ert-deftest chat-coding-eval-language-registry-matches-core-manifest ()
  "The reusable language inventory stays balanced and matches core tasks."
  (let* ((registry
          (chat-coding-eval-test--read-json
           chat-coding-eval-test-language-registry))
         (manifest
          (chat-coding-eval-test--read-json chat-coding-eval-test-manifest))
         (categories (alist-get 'categories registry))
         (cohorts (alist-get 'cohorts registry))
         (languages (alist-get 'languages registry))
         (core-languages
          (seq-filter
           (lambda (language)
             (equal "core" (alist-get 'cohort language)))
           languages))
         (extended-languages
          (seq-filter
           (lambda (language)
             (equal "extended" (alist-get 'cohort language)))
           languages))
         (manifest-languages
          (delete-dups
           (mapcar (lambda (task) (alist-get 'language task))
                   (alist-get 'tasks manifest))))
         (manifest-categories
          (delete-dups
           (mapcar (lambda (task) (alist-get 'category task))
                   (alist-get 'tasks manifest))))
         (language-ids (mapcar (lambda (language)
                                 (alist-get 'id language))
                               languages)))
    (should (= 1 (alist-get 'schemaVersion registry)))
    (should (= 6 (length categories)))
    (should (= 12 (length languages)))
    (should (= (length language-ids)
               (length (delete-dups (copy-sequence language-ids)))))
    (should (= 5 (length core-languages)))
    (should (= 7 (length extended-languages)))
    (should (equal (sort (copy-sequence categories) #'string<)
                   (sort manifest-categories #'string<)))
    (should
     (equal
      (sort (mapcar (lambda (language) (alist-get 'id language))
                    core-languages)
            #'string<)
      (sort manifest-languages #'string<)))
    (should
     (seq-every-p (lambda (language)
                    (equal "executable" (alist-get 'state language)))
                  core-languages))
    (should
     (seq-every-p (lambda (language)
                    (equal "executable" (alist-get 'state language)))
                  extended-languages))
    (dolist (cohort cohorts)
      (let* ((id (alist-get 'id cohort))
             (members
              (seq-filter (lambda (language)
                            (equal id (alist-get 'cohort language)))
                          languages)))
        (should (= (alist-get 'expectedLanguages cohort)
                   (length members)))
        (should (= (alist-get 'expectedTasks cohort)
                   (* (length members) (length categories))))))))

(ert-deftest chat-coding-eval-extended-manifest-is-complete-and-balanced ()
  "The M20 corpus has one safe executable task per language and category."
  (let* ((registry
          (chat-coding-eval-test--read-json
           chat-coding-eval-test-language-registry))
         (categories (alist-get 'categories registry))
         (extended-languages
          (mapcar
           (lambda (language) (alist-get 'id language))
           (seq-filter
            (lambda (language)
              (equal "extended" (alist-get 'cohort language)))
            (alist-get 'languages registry))))
         (raw-manifest
          (chat-coding-eval-test--read-json
           chat-coding-eval-test-extended-manifest))
         (raw-tasks (alist-get 'tasks raw-manifest))
         (task-timeout (alist-get 'taskTimeoutSeconds raw-manifest))
         (preflight-checks (alist-get 'preflightChecks raw-manifest))
         (required-executables
          (alist-get 'requiredExecutables raw-manifest))
         (tasks (chat-coding-eval-load-suite
                 chat-coding-eval-test-extended-manifest))
         (coverage (chat-coding-eval-suite-coverage tasks)))
    (should (= 42 (length tasks)))
    (should (= 300 task-timeout))
    (should
     (equal '(((name . "extended-fixture-offline-gate")
               (command "sh" "verify-extended-fixtures.sh")
               (timeoutSeconds . 240)))
            preflight-checks))
    (should
     (equal '("clang" "clang++" "java" "javac" "lein" "node" "sqlite3"
              "tsc" "zig")
            (sort (copy-sequence required-executables) #'string<)))
    (should (= 42 (alist-get 'taskCount coverage)))
    (should
     (equal (sort (copy-sequence extended-languages) #'string<)
            (mapcar #'car (alist-get 'languages coverage))))
    (dolist (language extended-languages)
      (let ((language-tasks
             (seq-filter
              (lambda (task)
                (equal language (chat-coding-eval-task-language task)))
              tasks)))
        (should (= 6 (length language-tasks)))
        (should
         (equal (sort (copy-sequence categories) #'string<)
                (sort
                 (mapcar #'chat-coding-eval-task-category language-tasks)
                 #'string<)))
        (should (= 1 (length
                      (delete-dups
                       (mapcar #'chat-coding-eval-task-fixture-id
                               language-tasks)))))))
    (dolist (task tasks)
      (should (= task-timeout
                 (chat-coding-eval-task-timeout-seconds task)))
      (should (file-directory-p
               (chat-coding-eval-task-fixture-directory task)))
      (should
       (stringp
        (chat-coding-eval-fixture-digest
         (chat-coding-eval-task-fixture-directory task))))
      (should (> (chat-coding-eval-task-declared-indexed-file-count task)
                 0)))
    (dolist (task raw-tasks)
      (when (seq-some (lambda (judge)
                        (equal "command" (alist-get 'type judge)))
                      (alist-get 'judges task))
        (should (assq 'generatedPaths task))))))

(ert-deftest chat-coding-eval-clojure-fixture-is-strictly-offline ()
  "Clojure fixture judging excludes implicit interactive dependencies."
  (let ((script
         (expand-file-name "coding-eval/clojure/test-one"
                           chat-test-fixtures-dir)))
    (with-temp-buffer
      (insert-file-contents script)
      (let ((contents (buffer-string)))
        (should (string-match-p
                 "export LEIN_OFFLINE=true"
                 contents))
        (should (string-match-p
                 "lein with-profile -base test :only"
                 contents))
        (should-not (string-match-p
                     "\\nlein test :only"
                     contents))))))

(ert-deftest chat-coding-eval-large-repo-manifest-is-an-exact-core-subset ()
  "The focused performance campaign cannot drift from its core task."
  (let* ((core (chat-coding-eval-test--read-json
                chat-coding-eval-test-manifest))
         (focused (chat-coding-eval-test--read-json
                   chat-coding-eval-test-large-repo-manifest))
         (tasks (alist-get 'tasks focused))
         (core-task
          (seq-find (lambda (task)
                      (equal "python-locate" (alist-get 'id task)))
                    (alist-get 'tasks core))))
    (should (= 1 (alist-get 'schemaVersion focused)))
    (should (= 1 (length tasks)))
    (should (equal core-task (car tasks)))
    (should (member "large-repo" (alist-get 'tags (car tasks))))))

(ert-deftest chat-coding-eval-core-reliability-smoke-is-an-exact-subset ()
  "The M21 recovery smoke reuses only the observed failing core tasks."
  (let* ((core (chat-coding-eval-test--read-json
                chat-coding-eval-test-manifest))
         (focused (chat-coding-eval-test--read-json
                   chat-coding-eval-test-core-reliability-smoke-manifest))
         (ids '("javascript-single-fix" "go-refactor" "rust-single-fix"
                "rust-multi-file" "rust-refactor" "rust-failing-test"))
         (expected
          (seq-filter (lambda (task)
                        (member (alist-get 'id task) ids))
                      (alist-get 'tasks core))))
    (should (equal "coding-core-v2" (alist-get 'corpusId core)))
    (should (= 300 (alist-get 'taskTimeoutSeconds core)))
    (should (equal "coding-core-reliability-smoke-v1"
                   (alist-get 'corpusId focused)))
    (should (= 300 (alist-get 'taskTimeoutSeconds focused)))
    (should (equal expected (alist-get 'tasks focused)))
    (dolist (task (chat-coding-eval-load-suite
                   chat-coding-eval-test-core-reliability-smoke-manifest))
      (should (= 300 (chat-coding-eval-task-timeout-seconds task))))))

(ert-deftest chat-coding-eval-go-refactor-diagnostic-is-an-exact-subset ()
  "The model-progress diagnostic reuses the canonical Go refactor task."
  (let* ((core (chat-coding-eval-test--read-json
                chat-coding-eval-test-manifest))
         (diagnostic
          (chat-coding-eval-test--read-json
           chat-coding-eval-test-go-refactor-diagnostic-manifest))
         (core-task
          (seq-find (lambda (task)
                      (equal "go-refactor" (alist-get 'id task)))
                    (alist-get 'tasks core))))
    (should (equal "coding-go-refactor-diagnostic-v1"
                   (alist-get 'corpusId diagnostic)))
    (should (= 300 (alist-get 'taskTimeoutSeconds diagnostic)))
    (should (equal (list core-task) (alist-get 'tasks diagnostic)))
    (let ((task (car (chat-coding-eval-load-suite
                      chat-coding-eval-test-go-refactor-diagnostic-manifest))))
      (should (= 300 (chat-coding-eval-task-timeout-seconds task))))))

(ert-deftest chat-coding-eval-rust-plan-diagnostic-is-an-exact-subset ()
  "The work-plan diagnostic reuses the canonical Rust multi-file task."
  (let* ((core (chat-coding-eval-test--read-json
                chat-coding-eval-test-manifest))
         (diagnostic
          (chat-coding-eval-test--read-json
           chat-coding-eval-test-rust-multi-file-diagnostic-manifest))
         (core-task
          (seq-find (lambda (task)
                      (equal "rust-multi-file" (alist-get 'id task)))
                    (alist-get 'tasks core))))
    (should (equal "coding-rust-multi-file-diagnostic-v1"
                   (alist-get 'corpusId diagnostic)))
    (should (= 300 (alist-get 'taskTimeoutSeconds diagnostic)))
    (should (equal (list core-task) (alist-get 'tasks diagnostic)))
    (let ((task (car (chat-coding-eval-load-suite
                      chat-coding-eval-test-rust-multi-file-diagnostic-manifest))))
      (should (= 300 (chat-coding-eval-task-timeout-seconds task))))))

(ert-deftest chat-coding-eval-javascript-refactor-diagnostic-is-an-exact-subset ()
  "The exact-command diagnostic reuses the canonical JavaScript refactor task."
  (let* ((core (chat-coding-eval-test--read-json
                chat-coding-eval-test-manifest))
         (diagnostic
          (chat-coding-eval-test--read-json
           chat-coding-eval-test-javascript-refactor-diagnostic-manifest))
         (core-task
          (seq-find (lambda (task)
                      (equal "javascript-refactor" (alist-get 'id task)))
                    (alist-get 'tasks core))))
    (should (equal "coding-javascript-refactor-diagnostic-v1"
                   (alist-get 'corpusId diagnostic)))
    (should (= 300 (alist-get 'taskTimeoutSeconds diagnostic)))
    (should (equal (list core-task) (alist-get 'tasks diagnostic)))
    (let ((task (car (chat-coding-eval-load-suite
                      chat-coding-eval-test-javascript-refactor-diagnostic-manifest))))
      (should (= 300 (chat-coding-eval-task-timeout-seconds task))))))

(ert-deftest chat-coding-eval-records-exact-verification-profile-evidence ()
  "Eval can prove planner argv matches the trusted task contract without copying it."
  (require 'chat-code-verify)
  (chat-test-with-temp-dir
   (let* ((chat-code-verify--profiles (make-hash-table :test 'equal))
          (chat-code-verify--profile-contexts (make-hash-table :test 'equal))
          (commands '(("node" "test.js" "normalize")))
          (_profile
           (chat-code-verify-plan
            temp-dir nil
            (list :session-id "eval-session" :task-id "agent-task"
                  :verification-commands commands)))
          (evidence
           (chat-coding-eval--verification-profile-evidence
            "eval-session" "agent-task" commands)))
     (should (equal "runtime-contract" (alist-get 'source evidence)))
     (should (= 1 (alist-get 'stepCount evidence)))
     (should (= 1 (alist-get 'contractCommandCount evidence)))
     (should (eq t (alist-get 'exactContractMatch evidence)))
     (should (equal (alist-get 'contractDigest evidence)
                    (alist-get 'profileDigest evidence)))
     (should-not (assq 'argv evidence)))))

(ert-deftest chat-coding-eval-mutation-smoke-is-an-exact-extended-subset ()
  "The focused mutation campaign cannot drift from extended task identity."
  (let* ((extended
          (chat-coding-eval-test--read-json
           chat-coding-eval-test-extended-manifest))
         (smoke
          (chat-coding-eval-test--read-json
           chat-coding-eval-test-extended-mutation-smoke-manifest))
         (extended-tasks (alist-get 'tasks extended))
         (smoke-tasks (alist-get 'tasks smoke))
         (expected
          (seq-filter
           (lambda (task)
             (equal "failing-test-fix" (alist-get 'category task)))
           extended-tasks)))
    (should (= 1 (alist-get 'schemaVersion smoke)))
    (should (equal "coding-extended-mutation-smoke-v1"
                   (alist-get 'corpusId smoke)))
    (should (= 7 (length smoke-tasks)))
    (should (equal expected smoke-tasks))
    (should (equal (alist-get 'requiredExecutables extended)
                   (alist-get 'requiredExecutables smoke)))
    (should (equal (alist-get 'preflightChecks extended)
                   (alist-get 'preflightChecks smoke)))
    (should (= (alist-get 'taskTimeoutSeconds extended)
               (alist-get 'taskTimeoutSeconds smoke)))
    (should
     (equal '("c" "clojure" "cpp" "java" "sql" "typescript" "zig")
            (sort
             (mapcar (lambda (task) (alist-get 'language task)) smoke-tasks)
             #'string<)))))

(ert-deftest chat-coding-eval-focused-smokes-are-exact-mutation-subsets ()
  "Each focused smoke reuses one canonical mutation task and its own tools."
  (let* ((extended-smoke
          (chat-coding-eval-test--read-json
           chat-coding-eval-test-extended-mutation-smoke-manifest))
         (canonical-tasks (alist-get 'tasks extended-smoke)))
    (dolist (entry chat-coding-eval-test-focused-mutation-smoke-manifests)
      (pcase-let* ((`(,language ,filename ,required-executables) entry)
                   (focused
                    (chat-coding-eval-test--read-json
                     (expand-file-name (concat "coding-eval/" filename)
                                       chat-test-fixtures-dir)))
                   (canonical
                    (seq-find
                     (lambda (task)
                       (equal (concat language "-failing-test")
                              (alist-get 'id task)))
                     canonical-tasks)))
        (should canonical)
        (should (= 1 (alist-get 'schemaVersion focused)))
        (should (equal (format "coding-%s-mutation-smoke-v1" language)
                       (alist-get 'corpusId focused)))
        (should (equal required-executables
                       (append (alist-get 'requiredExecutables focused) nil)))
        (should (= 300 (alist-get 'taskTimeoutSeconds focused)))
        (should (= 300
                   (chat-coding-eval-task-timeout-seconds
                    (car
                     (chat-coding-eval-load-suite
                      (expand-file-name (concat "coding-eval/" filename)
                                        chat-test-fixtures-dir))))))
        (should-not (assq 'preflightChecks focused))
        (should (equal (list canonical) (alist-get 'tasks focused)))))))

(defmacro chat-coding-eval-test-with-runtime (&rest body)
  "Run BODY with isolated evaluation records and workspaces."
  `(chat-test-with-temp-dir
    (let ((chat-eval-directory (expand-file-name "evals/" temp-dir))
          (chat-eval-auto-save t)
          (chat-coding-eval-workspace-directory
           (expand-file-name "workspaces/" temp-dir))
          (chat-coding-eval-clean-workspaces t))
      ,@body)))

(defun chat-coding-eval-test--wait (predicate &optional seconds)
  "Wait up to SECONDS for PREDICATE in batch tests."
  (let ((deadline (+ (float-time) (or seconds 3))))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.01))
    (funcall predicate)))

(defun chat-coding-eval-test--task (fixture judges &optional allowed timeout)
  "Return a minimal task using FIXTURE and JUDGES."
  (chat-coding-eval-task-create-record
   :schema-version chat-coding-eval-schema-version
   :id "test-task" :revision 1 :category "single-file-fix"
   :language "python" :description "test"
   :fixture-id "test-fixture" :fixture-directory fixture
   :prompt "Apply the requested test change."
   :allowed-paths (or allowed '("sample.py"))
   :timeout-seconds (or timeout 2)
   :judges judges))

(defun chat-coding-eval-test--small-manifest (root)
  "Create and return a two-task campaign manifest below ROOT."
  (let ((fixture (expand-file-name "fixture/" root))
        (manifest (expand-file-name "manifest.json" root)))
    (make-directory fixture t)
    (write-region "unchanged\n" nil
                  (expand-file-name "sample.txt" fixture) nil 'silent)
    (with-temp-file manifest
      (insert
       (json-encode
        `((schemaVersion . 1)
          (tasks
           . [((id . "resume-one") (revision . 1)
               (category . "read-only-review") (language . "text")
               (description . "first") (fixtureId . "resume-v1")
               (fixture . "fixture") (prompt . "Inspect the fixture.")
               (allowedPaths . ["sample.txt"]) (timeoutSeconds . 2)
               (judges . [((type . "no-change") (name . "unchanged"))]))
              ((id . "resume-two") (revision . 1)
               (category . "read-only-review") (language . "text")
               (description . "second") (fixtureId . "resume-v1")
               (fixture . "fixture") (prompt . "Inspect the fixture again.")
               (allowedPaths . ["sample.txt"]) (timeoutSeconds . 2)
               (judges . [((type . "no-change")
                            (name . "unchanged"))]))])))))
    manifest))

(ert-deftest chat-campaign-runner-rejects-ambiguous-integers ()
  "Campaign numeric configuration accepts only canonical positive integers."
  (let ((process-environment (copy-sequence process-environment)))
    (setenv "CHAT_TEST_INTEGER" "5")
    (should (= 5 (chat-campaign-runner--positive-integer
                  "CHAT_TEST_INTEGER" 1)))
    (dolist (value '("0" "-1" "5x" " 5" ""))
      (setenv "CHAT_TEST_INTEGER" value)
      (should-error
       (chat-campaign-runner--positive-integer "CHAT_TEST_INTEGER" 1)))))

(ert-deftest chat-campaign-runner-requires-exact-qualification-models ()
  "Known providers cannot silently run an alias or a costlier model."
  (should (equal "deepseek-v4-flash"
                 (chat-campaign-runner--validate-qualification-model
                  'deepseek "deepseek-v4-flash")))
  (should (equal "k3-256k"
                 (chat-campaign-runner--validate-qualification-model
                  'kimi-code "k3-256k")))
  (should-error
   (chat-campaign-runner--validate-qualification-model 'kimi-code "k3"))
  (should-error
   (chat-campaign-runner--validate-qualification-model
    'kimi-code "kimi-for-coding"))
  (should-error
   (chat-campaign-runner--validate-qualification-model
    'deepseek "deepseek-chat"))
  (should (equal "model-a"
                 (chat-campaign-runner--validate-qualification-model
                  'provider-a "model-a"))))

(ert-deftest chat-campaign-runner-freezes-revision-and-worktree ()
  "Only the expected clean checkout is eligible for an actual campaign."
  (let (dirty)
    (cl-letf (((symbol-function 'chat-campaign-runner--git-output)
               (lambda (_root &rest arguments)
                 (if (equal arguments '("rev-parse" "HEAD"))
                     "revision-a"
                   (if dirty " M changed.el" "")))))
      (should
       (chat-campaign-runner--validate-checkout
        "/repo" "revision-a" "Implementation" nil))
      (should-error
       (chat-campaign-runner--validate-checkout
        "/repo" "revision-b" "Implementation" nil))
      (setq dirty t)
      (should-error
       (chat-campaign-runner--validate-checkout
        "/repo" "revision-a" "Implementation" nil))
      (should-not
       (chat-campaign-runner--validate-checkout
        "/repo" "revision-a" "Implementation" t)))))

(ert-deftest chat-campaign-runner-readiness-is-bounded-and-model-specific ()
  "Readiness sends one short request to the exact provider and model."
  (let (observed)
    (cl-letf (((symbol-function 'chat-llm-request)
               (lambda (provider messages options)
                 (setq observed (list provider messages options))
                 '(:content "READY"
                   :reasoning "Checked the requested response."
                   :usage (:total-tokens 12)))))
      (should (equal "READY"
                     (chat-campaign-runner--provider-readiness
                      'provider-a "model-a"))))
    (should (eq 'provider-a (car observed)))
    (should (= 1 (length (cadr observed))))
    (should (equal "model-a" (plist-get (caddr observed) :model)))
    (should (= 512 (plist-get (caddr observed) :max-tokens)))
    (cl-letf (((symbol-function 'chat-llm-request)
               (lambda (&rest _arguments) '(:content "  \n"))))
      (should-error
       (chat-campaign-runner--provider-readiness
        'provider-a "model-a")))))

(ert-deftest chat-campaign-runner-validates-judge-executables-before-api-use ()
  "Campaign preflight resolves tools and rejects a missing executable."
  (let* ((fixture (expand-file-name "coding-eval/python"
                                    chat-test-fixtures-dir))
         (available
          (chat-coding-eval-test--task
           fixture
           '(((type . "command") (name . "available")
              (command . ("emacs" "--version"))))))
         (missing
          (chat-coding-eval-test--task
           fixture
           '(((type . "command") (name . "missing")
              (command . ("chat-campaign-tool-that-does-not-exist")))))))
    (let ((entry
           (car (chat-campaign-runner--validate-judge-executables
                 (list available)))))
      (should (equal "emacs" (alist-get 'name entry)))
      (should
       (equal (file-truename (executable-find "emacs"))
              (alist-get 'target entry)))
      (should
       (equal (expand-file-name (executable-find "emacs"))
              (alist-get 'path entry)))
      (should-not (string-empty-p (alist-get 'version entry))))
    (should-error
     (chat-campaign-runner--validate-judge-executables (list missing))
     :type 'error)
    (setf (chat-coding-eval-task-judges missing)
          '(((type . "command") (name . "wrapper")
             (command . ("sh" "test-one"))))
          (chat-coding-eval-task-required-executables missing)
          '("chat-campaign-hidden-tool-that-does-not-exist"))
    (should-error
     (chat-campaign-runner--validate-judge-executables (list missing))
     :type 'error)))

(ert-deftest chat-campaign-runner-manifest-preflight-is-bounded-and-versioned ()
  "Manifest setup is proven with its recorded toolchain before provider use."
  (chat-test-with-temp-dir
   (let* ((manifest (expand-file-name "manifest.json" temp-dir))
          (default-directory temp-dir)
          (success
           '(((name . "success")
              (command "sh" "-c" "printf ready")
              (timeoutSeconds . 1))))
          (timeout
           '(((name . "timeout")
              (command "sleep" "1")
              (timeoutSeconds . 0.01)))))
     (write-region "{}" nil manifest nil 'silent)
     (should
      (equal '("success")
             (chat-campaign-runner--run-manifest-preflight-checks
              manifest success '(((name . "sh"))))))
     (should-error
      (chat-campaign-runner--run-manifest-preflight-checks
       manifest success nil))
     (should-error
      (chat-campaign-runner--run-manifest-preflight-checks
       manifest timeout '(((name . "sleep")))))
     (should-not (get-process "chat-manifest-preflight-1")))))

(ert-deftest chat-coding-eval-toolchain-is-versioned-and-deterministic ()
  "Toolchain evidence includes hidden and direct dependencies in stable order."
  (let ((task
         (chat-coding-eval-test--task
          default-directory
          '(((type . "command") (name . "wrapped")
             (command . ("sh" "test-one")))))))
    (setf (chat-coding-eval-task-required-executables task)
          '("fake-compiler"))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (name) (format "/tools/%s" name)))
              ((symbol-function 'file-truename)
               (lambda (path) (concat path ".target")))
              ((symbol-function 'chat-coding-eval--probe-executable-version)
               (lambda (name path)
                 (format "%s@%s" name path))))
      (should
       (equal
        '(((name . "fake-compiler")
           (path . "/tools/fake-compiler")
           (target . "/tools/fake-compiler.target")
           (version . "fake-compiler@/tools/fake-compiler"))
          ((name . "sh")
           (path . "/tools/sh")
           (target . "/tools/sh.target")
           (version . "sh@/tools/sh")))
        (chat-coding-eval-resolve-toolchain (list task)))))))

(ert-deftest chat-coding-eval-toolchain-probe-records-real-shell ()
  "The bounded version probe records the resolved local shell identity."
  (let* ((task
          (chat-coding-eval-test--task
           default-directory
           '(((type . "command") (name . "shell")
              (command . ("sh" "-c" "exit 0"))))))
         (toolchain (chat-coding-eval-resolve-toolchain (list task)))
         (entry (car toolchain)))
    (should (equal "sh" (alist-get 'name entry)))
    (should (file-name-absolute-p (alist-get 'path entry)))
    (should (file-name-absolute-p (alist-get 'target entry)))
    (should (stringp (alist-get 'version entry)))
    (should (string-match-p "\\`shell=" (alist-get 'version entry)))
    (should-not (string-match-p "\\bProcess\\b"
                                (alist-get 'version entry)))))

(ert-deftest chat-coding-eval-toolchain-rejects-unknown-and-timed-out-probes ()
  "Tool identity cannot be guessed or allowed to leave a live probe."
  (let ((task
         (chat-coding-eval-test--task
          default-directory
          '(((type . "no-change") (name . "unchanged"))))))
    (setf (chat-coding-eval-task-required-executables task) '("true"))
    (should-error (chat-coding-eval-resolve-toolchain (list task)))
    (let ((chat-coding-eval--tool-version-probes
           (cons '("sleep" "1") chat-coding-eval--tool-version-probes))
          (chat-coding-eval-tool-version-timeout-seconds 0.01))
      (setf (chat-coding-eval-task-required-executables task) '("sleep"))
      (should-error (chat-coding-eval-resolve-toolchain (list task)))
      (should-not (get-process "chat-tool-version-sleep")))))

(ert-deftest chat-campaign-runner-runtime-home-keeps-an-absolute-directory ()
  "Changing HOME cannot leave subprocesses resolving an obsolete ~/ path."
  (chat-test-with-temp-dir
   (let* ((process-environment (copy-sequence process-environment))
          (harness (file-name-as-directory (expand-file-name "harness" temp-dir)))
          (developer-home (expand-file-name "developer" temp-dir))
          (rustup-home (expand-file-name ".rustup" developer-home))
          (home (expand-file-name "home" temp-dir))
          (chat-campaign-runner--harness-root harness)
          (default-directory "~/project/"))
     (make-directory harness t)
     (make-directory rustup-home t)
     (setenv "HOME" developer-home)
     (setenv "RUSTUP_HOME" nil)
     (should (equal (file-name-as-directory home)
                    (chat-campaign-runner--install-runtime-home home)))
     (should (equal (file-name-as-directory home) (getenv "HOME")))
     (should (equal (file-truename rustup-home) (getenv "RUSTUP_HOME")))
     (should (equal harness default-directory)))))

(ert-deftest chat-campaign-runner-runtime-home-allows-missing-developer-home ()
  "An isolated campaign can start without an inherited developer HOME."
  (chat-test-with-temp-dir
   (let* ((process-environment nil)
          (harness (file-name-as-directory (expand-file-name "harness" temp-dir)))
          (home (expand-file-name "home" temp-dir))
          (chat-campaign-runner--harness-root harness)
          (default-directory harness))
     (make-directory harness t)
     (should (equal (file-name-as-directory home)
                    (chat-campaign-runner--install-runtime-home home)))
     (should (equal (file-name-as-directory home) (getenv "HOME")))
     (should-not (getenv "RUSTUP_HOME")))))

(ert-deftest chat-campaign-runner-keeps-result-contracts-harness-owned ()
  "A frozen implementation cannot supply campaign persistence functions."
  (chat-test-with-temp-dir
   (let* ((harness (file-name-as-directory
                    (expand-file-name "harness" temp-dir)))
          (implementation (file-name-as-directory
                           (expand-file-name "implementation" temp-dir)))
          (chat-campaign-runner--harness-root harness)
          loaded)
     (dolist (contract chat-campaign-runner--harness-contracts)
       (let ((file (expand-file-name (car contract) harness)))
         (make-directory (file-name-directory file) t)
         (write-region "" nil file nil 'silent)))
     (make-directory implementation t)
     (cl-letf (((symbol-function 'load)
                (lambda (file &rest _arguments) (push file loaded)))
               ((symbol-function 'symbol-file)
                (lambda (symbol &optional _type)
                  (expand-file-name
                   (car (rassq symbol chat-campaign-runner--harness-contracts))
                   harness))))
       (chat-campaign-runner--load-harness-contracts implementation))
     (should
      (equal (mapcar (lambda (contract)
                       (expand-file-name (car contract) harness))
                     chat-campaign-runner--harness-contracts)
             (nreverse loaded))))))

(ert-deftest chat-campaign-runner-rejects-foreign-result-contract-owner ()
  "Runner fails closed when a persistence function still belongs elsewhere."
  (chat-test-with-temp-dir
   (let* ((harness (file-name-as-directory
                    (expand-file-name "harness" temp-dir)))
          (foreign (expand-file-name "foreign/chat-eval.el" temp-dir))
          (chat-campaign-runner--harness-root harness))
     (make-directory harness t)
     (make-directory (file-name-directory foreign) t)
     (write-region "" nil foreign nil 'silent)
     (cl-letf (((symbol-function 'symbol-file)
                (lambda (_symbol &optional _type) foreign)))
       (should-error
        (chat-campaign-runner--load-harness-contracts harness)
        :type 'error)))))

(ert-deftest chat-campaign-runner-always-isolates-and-cleans-runtime-home ()
  "The runner never reads developer state when no runtime HOME is supplied."
  (chat-test-with-temp-dir
   (let* ((process-environment (copy-sequence process-environment))
          (developer-home (expand-file-name "developer" temp-dir))
          (harness (file-name-as-directory
                    (expand-file-name "harness" temp-dir)))
          (chat-campaign-runner--harness-root harness)
          observed-home observed-campaign-root)
     (make-directory developer-home t)
     (make-directory harness t)
     (setenv "HOME" developer-home)
     (setenv "CHAT_CAMPAIGN_RUNTIME_HOME" nil)
     (setenv "CHAT_CAMPAIGN_DIRECTORY" nil)
     (chat-campaign-runner--call-with-isolated-runtime
      (lambda ()
        (setq observed-home (getenv "HOME")
              observed-campaign-root (getenv "CHAT_CAMPAIGN_DIRECTORY"))
        (should (file-directory-p observed-home))))
     (should-not (file-exists-p observed-home))
     (should
      (equal (expand-file-name ".chat/evaluations/coding-campaigns/"
                               developer-home)
             observed-campaign-root)))))

(ert-deftest chat-campaign-runner-starts-new-and-resumes-existing-campaigns ()
  "The batch runner resumes only an existing validated campaign directory."
  (chat-test-with-temp-dir
   (let ((existing (expand-file-name "existing" temp-dir))
         (new (expand-file-name "new" temp-dir))
         (toolchain '(((name . "fixture") (path . "/tools/fixture")
                       (target . "/tools/fixture")
                       (version . "fixture 1"))))
         calls)
     (make-directory existing)
     (cl-letf (((symbol-function 'chat-coding-eval-resume-live)
                (lambda (&rest arguments)
                  (push (cons 'resume arguments) calls)
                  'resumed))
               ((symbol-function 'chat-coding-eval-run-live)
                (lambda (&rest arguments)
                  (push (cons 'start arguments) calls)
                  'started)))
       (should
        (eq 'resumed
            (chat-campaign-runner--start-or-resume
             existing 'provider-a 5 "/manifest.json" "model-a" "campaign-a"
             "revision-a" "current" toolchain)))
       (should
        (equal (list 'resume existing "/manifest.json" "revision-a" toolchain)
               (car calls)))
       (should
        (eq 'started
            (chat-campaign-runner--start-or-resume
             new 'provider-a 5 "/manifest.json" "model-a" "campaign-b"
             "revision-a" "baseline" toolchain)))
       (should
        (equal (list 'start 'provider-a 5 "/manifest.json" "model-a"
                     "campaign-b" "revision-a" "baseline" toolchain)
               (car calls)))))))

(ert-deftest chat-coding-eval-suite-has-fixed-balanced-coverage ()
  "The baseline contains thirty tasks with balanced category coverage."
  (let* ((tasks (chat-coding-eval-load-suite
                 chat-coding-eval-test-manifest))
         (coverage (chat-coding-eval-suite-coverage tasks)))
    (should (= 30 (alist-get 'taskCount coverage)))
    (should (equal '(5 5 5 5 5 5)
                   (mapcar #'cdr (alist-get 'categories coverage))))
    (should (equal '(6 6 6 6 6)
                   (mapcar #'cdr (alist-get 'languages coverage))))
    (should (equal '(("large-repo" . 1))
                   (alist-get 'tags coverage)))
    (dolist (task tasks)
      (should (= 300 (chat-coding-eval-task-timeout-seconds task))))
    (let ((large
           (seq-find
            (lambda (task)
              (member "large-repo" (chat-coding-eval-task-tags task)))
            tasks)))
      (should large)
      (should (= 10000
                 (chat-coding-eval-task-declared-indexed-file-count large)))
      (should (= 10001 (chat-coding-eval-task-declared-file-count large)))
      (should (= 64 (length
                     (chat-coding-eval-task-fixture-generator-digest large)))))
    (dolist (task tasks)
      (let ((left (chat-coding-eval-fixture-digest
                   (chat-coding-eval-task-fixture-directory task)))
            (right (chat-coding-eval-fixture-digest
                    (chat-coding-eval-task-fixture-directory task))))
        (should (= 64 (length left)))
        (should (equal left right))))))

(ert-deftest chat-coding-eval-manifest-timeout-is-inherited-and-overridable ()
  "A corpus timeout applies uniformly unless a task declares a tighter bound."
  (chat-test-with-temp-dir
   (let ((fixture (expand-file-name "fixture/" temp-dir))
         (manifest (expand-file-name "manifest.json" temp-dir)))
     (make-directory fixture t)
     (write-region "sample\n" nil
                   (expand-file-name "sample.txt" fixture) nil 'silent)
     (with-temp-file manifest
       (insert
        (json-encode
         '((schemaVersion . 1)
           (taskTimeoutSeconds . 300)
           (tasks
            . [((id . "default") (revision . 1)
                (category . "read-only-review") (language . "text")
                (description . "default") (fixtureId . "fixture")
                (fixture . "fixture") (prompt . "Inspect the fixture.")
                (allowedPaths . ["sample.txt"])
                (judges . [((type . "no-change") (name . "unchanged"))]))
               ((id . "override") (revision . 1)
                (category . "read-only-review") (language . "text")
                (description . "override") (fixtureId . "fixture")
                (fixture . "fixture") (prompt . "Inspect the fixture.")
                (allowedPaths . ["sample.txt"]) (timeoutSeconds . 30)
                (judges . [((type . "no-change")
                             (name . "unchanged"))]))])))))
     (let ((tasks (chat-coding-eval-load-suite manifest)))
       (should (= 300 (chat-coding-eval-task-timeout-seconds (car tasks))))
       (should (= 30 (chat-coding-eval-task-timeout-seconds (cadr tasks)))))
     (with-temp-file manifest
       (insert
        (json-encode
         '((schemaVersion . 1) (taskTimeoutSeconds . 0)
           (tasks . [])))))
     (should-error (chat-coding-eval-load-suite manifest)))))

(ert-deftest chat-coding-eval-suite-declares-language-build-artifacts ()
  "Executable fixtures separate generated caches from writable source scope."
  (let ((tasks (chat-coding-eval-load-suite
                chat-coding-eval-test-manifest)))
    (dolist (task tasks)
      (let ((category (chat-coding-eval-task-category task))
            (language (chat-coding-eval-task-language task))
            (generated (chat-coding-eval-task-generated-paths task)))
        (when (member category '("single-file-fix" "multi-file-change"
                                 "refactor" "failing-test-fix"))
          (pcase language
            ("elisp"
             (should (equal '("sample.elc") generated))
             (should-not (member "sample.elc"
                                 (chat-coding-eval-task-allowed-paths task))))
            ("python"
             (should (equal '("__pycache__" ".pytest_cache") generated))
             (should-not (member "__pycache__"
                                 (chat-coding-eval-task-allowed-paths task))))
            ("go"
             (should (equal '(".gocache" ".gotmp") generated))
             (should-not (member ".gocache"
                                 (chat-coding-eval-task-allowed-paths task))))))))))

(ert-deftest chat-coding-eval-generator-materializes-bounded-source-files ()
  "A generator creates deterministic files and records their measured count."
  (chat-coding-eval-test-with-runtime
   (let* ((fixture (expand-file-name "fixture/" temp-dir))
          (generator
           '((schemaVersion . 1) (kind . "source-tree")
             (generatedFiles . 3) (bucketSize . 2)
             (pathTemplate . "pkg/{{bucket}}/item_{{index}}.py")
             (contentTemplate . "VALUE = {{index}}\n")))
          (task
           (chat-coding-eval-task-create-record
            :schema-version chat-coding-eval-schema-version
            :id "generated" :revision 1 :category "locate-explain"
            :language "python" :description "generated"
            :fixture-id "generated-v1" :fixture-directory fixture
            :fixture-generator generator :fixture-generator-digest "digest"
            :prompt "Inspect the generated files." :allowed-paths '("base.py")
            :timeout-seconds 2 :tags nil
            :judges '(((type . "no-change") (name . "unchanged")))))
          result)
     (make-directory fixture t)
     (write-region "BASE = 1\n" nil (expand-file-name "base.py" fixture))
     (chat-coding-eval-run
      task
      (lambda (_task workspace done)
        (should (file-exists-p (expand-file-name "pkg/1/item_2.py" workspace)))
        (funcall done 'completed "inspected" nil))
      :on-complete (lambda (value _state) (setq result value)))
     (should result)
     (should (eq 'passed (chat-eval-result-status result)))
     (should (= 4 (alist-get 'fixtureFileCount
                             (chat-eval-result-metadata result))))
     (should (= 4 (alist-get 'fixtureIndexedFileCount
                             (chat-eval-result-metadata result)))))))

(ert-deftest chat-coding-eval-generator-refuses-path-escape ()
  "Rendered generator paths cannot escape the disposable workspace."
  (chat-test-with-temp-dir
   (let ((task
          (chat-coding-eval-task-create-record
           :fixture-generator
           '((generatedFiles . 1) (bucketSize . 1)
             (pathTemplate . "../item_{{index}}.py")
             (contentTemplate . "VALUE = 1\n")))))
     (should-error
      (chat-coding-eval--materialize-generator task temp-dir)))))

(ert-deftest chat-coding-eval-model-name-uses-provider-registration ()
  "Live Eval separates provider identity from its concrete model name."
  (let ((chat-llm-providers (copy-sequence chat-llm-providers)))
    (chat-llm-register-provider
     'coding-eval-provider :name "Eval" :model "model-v2" :api-key "test")
    (should (equal "model-v2"
                   (chat-coding-eval--model-name
                    'coding-eval-provider nil)))
    (should (equal "model-v3"
                   (chat-coding-eval--model-name
                    'coding-eval-provider "model-v3")))))

(ert-deftest chat-coding-eval-agent-binds-code-root-and-counts-tool-events ()
  "Live Eval uses its workspace as project context and records real events."
  (chat-test-with-temp-dir
   (let* ((chat-coding-eval-max-tool-error-records 1)
          (chat-coding-eval-max-tool-error-summary-chars 80)
          (chat-coding-eval-max-tool-call-summary-records 2)
          (chat-code-verify--profiles (make-hash-table :test 'equal))
          (chat-code-verify--profile-contexts (make-hash-table :test 'equal))
          (chat-work-plan-evidence-resolver-functions
           (list (lambda (_candidate _task-id evidence-id)
                   (equal evidence-id "verification:passed"))))
          (commands '(("node" "test.js" "normalize")))
          (task
           (chat-coding-eval-test--task
            temp-dir
            `(((type . "command") (name . "targeted")
               (command . ,(car commands))))))
          config status metadata)
     (cl-letf (((symbol-function 'chat-agent-start)
                (lambda (value) (setq config value) nil)))
       (funcall (chat-coding-eval-agent-executor 'eval-provider "model")
                task temp-dir
                (lambda (value _content details)
                  (setq status value
                        metadata details))))
     (let ((session (plist-get config :session))
           (on-event (plist-get config :on-event))
           (model-observer
            (plist-get (plist-get config :request-options)
                       :event-observer)))
       (should (eq 'eval-provider (plist-get config :provider)))
       (should (equal "model" (plist-get config :model)))
       (should (equal "model"
                      (plist-get (plist-get config :request-options) :model)))
       (should (functionp model-observer))
       (should (chat-code-session-p session))
       (should (equal (file-name-as-directory temp-dir)
                      (file-name-as-directory
                       (chat-code-session-project-root session))))
       (chat-code-verify-plan
        temp-dir nil
        (list :session-id (chat-session-id session)
              :task-id (plist-get config :task-id)
              :verification-commands commands))
       (let ((plan
              (chat-work-plan-create
               session "Diagnose the bounded task"
               '(((id . "implement") (title . "Implement")
                  (acceptance . "Change is present"))
                 ((id . "verify") (title . "Verify")
                  (acceptance . "Focused check passes")
                  (dependencies . ["implement"]))))))
         (setq plan
               (chat-work-plan-transition-item
                session (chat-work-plan-id plan) (chat-work-plan-revision plan)
                "implement" 'in-progress))
         (setq plan
               (chat-work-plan-transition-item
                session (chat-work-plan-id plan) (chat-work-plan-revision plan)
                "implement" 'completed :evidence '("verification:passed")))
         (setq plan
               (chat-work-plan-transition-item
                session (chat-work-plan-id plan) (chat-work-plan-revision plan)
                "verify" 'in-progress))
         (chat-work-plan-transition-item
          session (chat-work-plan-id plan) (chat-work-plan-revision plan)
          "verify" 'blocked
          :blocker-reason "Declared verification remained unavailable"))
       (funcall model-observer
                (chat-model-event-make
                 'started 'eval-provider "model" "request-1" 1 nil))
       (funcall on-event
                '(:type tool-event
                  :event (:type approval-guard-pending)))
       (funcall on-event
                '(:type tool-event :event (:type approval)))
       (funcall on-event
                `(:type tool-event :step 3
                  :event (:type tool-error :index 2 :tool "files_write"
                          :error-type file-not-read
                          :result-summary
                          ,(concat "file was not read\n" (make-string 200 ?x)))))
       (funcall on-event
                '(:type execution-error :step 4 :tool "shell_execute"
                  :result-summary "process failed"))
       (funcall on-event '(:type turn-start))
       (funcall on-event
                (list :type 'model-usage
                      :usage
                      (list :input-tokens 11 :output-tokens 4 :total-tokens 15
                            :raw `((provider_detail . ,(make-string 5000 ?x))))))
       (funcall model-observer
                (chat-model-event-make
                 'started 'eval-provider "model" "request-2" 1 nil))
       (funcall on-event '(:type turn-start))
       (funcall on-event
                (list :type 'model-usage
                      :usage
                      (list :input-tokens 21 :output-tokens 8 :total-tokens 29
                            :raw `((provider_detail . ,(make-string 5000 ?y))))))
       (funcall on-event
                '(:type agent-end :status completed :content "done"
                  :steps 1
                  :tool-calls ((:name "files_read")
                               (:name "shell_execute")
                               (:name "files_read")
                               (:name "files_patch"))
                  :tool-results ("read" "ran" "read" "patched"))))
     (should (eq status 'completed))
     (should (= 4 (alist-get 'toolCallCount metadata)))
     (should
      (equal '(((tool . "files_patch") (count . 1))
               ((tool . "files_read") (count . 2)))
             (alist-get 'toolCallSummary metadata)))
     (should (= 1 (alist-get 'toolCallSummaryTruncated metadata)))
     (should (= 2 (alist-get 'toolErrorCount metadata)))
     (let* ((plan (alist-get 'workPlanFinalState metadata))
            (items (append (alist-get 'items plan) nil))
            (implemented (seq-find (lambda (item)
                                     (equal "implement" (alist-get 'id item)))
                                   items))
            (blocked (seq-find (lambda (item)
                                 (equal "verify" (alist-get 'id item)))
                               items)))
       (should (stringp (alist-get 'id plan)))
       (should (= 5 (alist-get 'revision plan)))
       (should (equal "blocked" (alist-get 'status plan)))
       (should-not (assq 'objective plan))
       (should (= 2 (length items)))
       (should (seq-every-p (lambda (item)
                              (and (not (assq 'title item))
                                   (not (assq 'acceptance item))))
                            items))
       (should (equal "completed" (alist-get 'status implemented)))
       (should
        (equal '("verification:passed")
               (append (alist-get 'evidenceIds implemented) nil)))
       (should (equal "blocked" (alist-get 'status blocked)))
       (should
        (equal "Declared verification remained unavailable"
               (alist-get 'blockerReason blocked))))
     (let* ((errors (alist-get 'toolErrors metadata))
            (error (car errors)))
       (should (= 1 (length errors)))
       (should (= 1 (alist-get 'toolErrorRecordsTruncated metadata)))
       (should (equal "tool-error" (alist-get 'eventType error)))
       (should (= 3 (alist-get 'step error)))
       (should (= 2 (alist-get 'index error)))
       (should (equal "files_write" (alist-get 'tool error)))
       (should (equal "file-not-read" (alist-get 'errorType error)))
       (should (<= (length (alist-get 'summary error)) 80))
       (should-not (string-match-p "\n" (alist-get 'summary error))))
     (should (= 2 (alist-get 'approvalCount metadata)))
     (should (= 11 (plist-get (alist-get 'firstRequestTokenUsage metadata)
                              :input-tokens)))
     (should-not (plist-member (alist-get 'firstRequestTokenUsage metadata)
                               :raw))
     (should (= 29 (plist-get (alist-get 'finalRequestTokenUsage metadata)
                              :total-tokens)))
     (should-not (plist-member (alist-get 'finalRequestTokenUsage metadata)
                               :raw))
     (should (= 44 (plist-get (alist-get 'totalTokenUsage metadata)
                              :total-tokens)))
     (should (= 2 (alist-get 'requestCount metadata)))
     (should (= 2 (alist-get 'usageSampleCount metadata)))
     (let ((profile (alist-get 'verificationProfile metadata)))
       (should (equal "runtime-contract" (alist-get 'source profile)))
       (should (eq t (alist-get 'exactContractMatch profile)))
       (should (equal (alist-get 'contractDigest profile)
                      (alist-get 'profileDigest profile)))
       (should-not (assq 'argv profile)))
     (should
      (equal '(((provider . "eval-provider")
                (model . "model")
                (requestId . "request-1"))
               ((provider . "eval-provider")
                (model . "model")
                (requestId . "request-2")))
             (alist-get 'requestModels metadata))))))

(ert-deftest chat-coding-eval-agent-rejects-model-identity-drift ()
  "Live Eval fails closed when a real request uses another model."
  (chat-test-with-temp-dir
   (let* ((task (chat-coding-eval-test--task temp-dir nil))
          config status metadata)
     (cl-letf (((symbol-function 'chat-agent-start)
                (lambda (value) (setq config value) nil)))
       (funcall (chat-coding-eval-agent-executor 'eval-provider "model")
                task temp-dir
                (lambda (value _content details)
                  (setq status value
                        metadata details))))
     (let ((on-event (plist-get config :on-event))
           (model-observer
            (plist-get (plist-get config :request-options)
                       :event-observer)))
       (funcall model-observer
                (chat-model-event-make
                 'started 'eval-provider "other-model" "request-1" 1 nil))
       (funcall on-event
                '(:type agent-end :status completed :content "done"
                  :steps 1 :tool-calls nil :tool-results nil)))
     (should (eq status 'error))
     (should (string-match-p
              "model identity drift: expected eval-provider/model"
              (alist-get 'failureReason metadata))))))

(ert-deftest chat-coding-eval-agent-rejects-missing-request-identity ()
  "Live Eval cannot pass without a normalized transport start event."
  (chat-test-with-temp-dir
   (let* ((task (chat-coding-eval-test--task temp-dir nil))
          config status metadata)
     (cl-letf (((symbol-function 'chat-agent-start)
                (lambda (value) (setq config value) nil)))
       (funcall (chat-coding-eval-agent-executor 'eval-provider "model")
                task temp-dir
                (lambda (value _content details)
                  (setq status value metadata details))))
     (funcall (plist-get config :on-event)
              '(:type agent-end :status completed :content "done"
                :steps 1 :tool-calls nil :tool-results nil))
     (should (eq status 'error))
     (should (string-match-p
              "observed nil"
              (alist-get 'failureReason metadata))))))

(ert-deftest chat-campaign-runner-adapts-frozen-agent-config-contract ()
  "The frozen Agent receives its provider and concrete model without defaults."
  (let* ((common '(:messages nil
                   :request-options (:model "model-v2"
                                     :event-observer ignore)))
         (config
          (chat-campaign-runner--agent-config-v1
           'provider-a "model-v2" common)))
    (should (eq 'provider-a (plist-get config :model)))
    (should-not (plist-member config :provider))
    (should (equal "model-v2"
                   (plist-get (plist-get config :request-options) :model)))
    (should (eq 'ignore
                (plist-get (plist-get config :request-options)
                           :event-observer)))))

(ert-deftest chat-campaign-runner-legacy-observer-is-scoped-and-stripped ()
  "The frozen runtime adapter observes only explicitly instrumented requests."
  (let (observed transport-options delivered)
    (chat-campaign-runner--model-observer-v0-advice
     (lambda (_provider _messages callback options)
       (setq transport-options options)
       (funcall callback
                (chat-model-event-make
                 'started 'provider-a "model-v2" "request-1" 1 nil)))
     'provider-a nil
     (lambda (event) (push event delivered))
     (list :model "model-v2"
           :event-observer (lambda (event) (push event observed))))
    (should (= 1 (length observed)))
    (should (equal observed delivered))
    (should-not (plist-member transport-options :event-observer))))

(ert-deftest chat-campaign-runner-projects-frozen-capability-schema ()
  "The frozen capability snapshot contains only fields its runtime declares."
  (let ((chat-llm-providers (copy-sequence chat-llm-providers)))
    (chat-llm-register-provider
     'frozen-capability-provider :model "model-v1"
     :capabilities '(:stream t :tools t :reasoning t))
    (let ((snapshot
           (chat-campaign-runner--capability-snapshot-v1
            'frozen-capability-provider "model-v1")))
      (should (equal "frozen-capability-provider"
                     (alist-get 'provider snapshot)))
      (should (equal "model-v1" (alist-get 'model snapshot)))
      (should-not (assq 'reasoningReplay snapshot)))))

(ert-deftest chat-campaign-runner-rejects-unknown-frozen-protocols ()
  "A frozen checkout must declare a protocol supported by the harness."
  (should-error
   (chat-campaign-runner--configure-implementation-contracts 3 1 2)
   :type 'error)
  (should-error
   (chat-campaign-runner--configure-implementation-contracts 2 3 2)
   :type 'error)
  (should-error
   (chat-campaign-runner--configure-implementation-contracts 2 1 3)
   :type 'error))

(ert-deftest chat-coding-eval-total-usage-never-fills-a-missing-counter ()
  "A partial provider usage field is omitted instead of counted as zero."
  (let ((total
         (chat-coding-eval--sum-token-usage
          '((:input-tokens 10 :output-tokens 3)
            (:input-tokens 20)))))
    (should (= 30 (plist-get total :input-tokens)))
    (should-not (plist-member total :output-tokens))))

(ert-deftest chat-coding-eval-agent-projects-exact-command-judges ()
  "The live agent sees the same targeted argv that judges its result."
  (chat-test-with-temp-dir
   (let* ((task
           (chat-coding-eval-test--task
            temp-dir
            '(((type . "command") (name . "targeted")
               (command . ("emacs" "-Q" "--eval"
                           "(ert-run-tests-batch-and-exit 'sample-test)"))))))
          config)
     (cl-letf (((symbol-function 'chat-agent-start)
                (lambda (value) (setq config value) nil)))
       (funcall (chat-coding-eval-agent-executor 'eval-provider "model")
                task temp-dir #'ignore))
     (let* ((prompt (chat-message-content
                     (car (plist-get config :messages))))
            (session (plist-get config :session))
            (task-id (plist-get config :task-id))
            (contract
             (chat-session-metadata-get session 'verificationContract)))
       (should (equal task-id (alist-get 'taskId contract)))
       (should (equal "evaluation" (alist-get 'source contract)))
       (should
        (equal '("emacs" "-Q" "--eval"
                 "(ert-run-tests-batch-and-exit 'sample-test)")
               (alist-get 'argv (car (alist-get 'commands contract)))))
       (should (string-match-p
                (regexp-quote "Verification commands (run these exact targeted checks):")
                prompt))
       (should (string-match-p
                (regexp-quote
                 "emacs -Q --eval \\(ert-run-tests-batch-and-exit\\ \\'sample-test\\)")
                prompt))
       (should (string-match-p
                (regexp-quote
                 "These commands are the complete task verification contract.")
                prompt))
       (should (string-match-p
                (regexp-quote
                 "This is an intentionally bounded single-file repair.")
                prompt))
       (should (string-match-p
                (regexp-quote
                 "programming_plan_skip")
                prompt))
       (should (string-match-p
                (regexp-quote "do not run a broader test suite")
                prompt))))))

(ert-deftest chat-coding-eval-execution-guidance-is-shape-specific ()
  "Only a bounded one-file repair receives the audited skip workflow."
  (let ((task
         (chat-coding-eval-test--task
          default-directory
          '(((type . "command") (name . "targeted")
             (command . ("sh" "test-one")))))))
    (should (string-match-p
             "single-bounded-action"
             (chat-coding-eval--execution-guidance task)))
    (should (string-match-p
             "only once for this task"
             (chat-coding-eval--execution-guidance task)))
    (should (string-match-p
             "newly visible write tool immediately"
             (chat-coding-eval--execution-guidance task)))
    (should (string-match-p
             "create a durable TODO plan"
             (chat-coding-eval--execution-guidance task)))
    (setf (chat-coding-eval-task-allowed-paths task)
          '("sample.py" "helper.py"))
    (should (string-empty-p
             (chat-coding-eval--execution-guidance task)))
    (setf (chat-coding-eval-task-allowed-paths task) '("sample.py")
          (chat-coding-eval-task-category task) "refactor")
    (should (string-empty-p
             (chat-coding-eval--execution-guidance task)))))

(ert-deftest chat-coding-eval-agent-omits-guidance-without-command-judge ()
  "Non-command judges do not invent an executable verification step."
  (let ((task (chat-coding-eval-test--task
               default-directory
               '(((type . "no-change") (name . "unchanged"))))))
    (should (string-empty-p
             (chat-coding-eval--verification-guidance task)))))

(ert-deftest chat-coding-eval-campaign-is-isolated-and-immutable ()
  "A live campaign records one reproducible configuration in a fresh directory."
  (chat-test-with-temp-dir
   (let* ((chat-coding-eval-campaign-directory
           (expand-file-name "campaigns/" temp-dir))
          (campaign
           (chat-coding-eval-prepare-campaign
            "baseline-001" 'provider-a "model-a" 5
            chat-coding-eval-test-manifest
            :implementation-revision "baseline-revision"
            :role "baseline"
            :toolchain
            '(((name . "emacs") (path . "/tools/emacs")
               (target . "/tools/emacs")
               (version . "GNU Emacs test")))))
          (directory (plist-get campaign :directory))
          (descriptor (plist-get campaign :descriptor)))
     (should (file-exists-p (expand-file-name "campaign.json" directory)))
     (should (= 150 (alist-get 'expectedResultCount descriptor)))
     (should (= 64 (length (alist-get 'configurationDigest descriptor))))
     (should (equal "baseline-revision"
                    (alist-get 'implementationRevision descriptor)))
     (should
      (equal "GNU Emacs test"
             (alist-get
              'version (car (alist-get 'toolchain descriptor)))))
     (should-error (chat-coding-eval--complete-campaign campaign nil))
     (should-not (file-exists-p
                  (expand-file-name "completion.json" directory)))
     (should-error
      (chat-coding-eval-prepare-campaign
       "baseline-001" 'provider-a "model-a" 5
       chat-coding-eval-test-manifest
       :implementation-revision "baseline-revision"
       :role "baseline"
       :toolchain
       '(((name . "emacs") (path . "/tools/emacs")
          (target . "/tools/emacs")
          (version . "GNU Emacs test"))))))))

(ert-deftest chat-coding-eval-suite-persists-only-in-its-result-directory ()
  "Suite result routing cannot mix campaign records into the global store."
  (chat-coding-eval-test-with-runtime
   (let* ((task (car (chat-coding-eval-load-suite
                      chat-coding-eval-test-manifest)))
          (campaign-directory (expand-file-name "campaign/" temp-dir))
          results)
     (make-directory campaign-directory t)
     (setf (chat-coding-eval-task-judges task)
           '(((type . "no-change") (name . "unchanged"))))
     (chat-coding-eval-run-suite
      (list task)
      (lambda (_task _workspace done)
        (funcall done 'completed "done" '((model . "fixed"))))
      :result-directory campaign-directory
      :result-metadata '((campaignId . "campaign-001"))
      :on-complete (lambda (value _state) (setq results value)))
     (should (chat-coding-eval-test--wait (lambda () results)))
     (should (= 1 (length results)))
     (should (equal "campaign-001"
                    (alist-get 'campaignId
                               (chat-eval-result-metadata (car results)))))
     (should (= 1 (alist-get 'repetition
                             (chat-eval-result-metadata (car results)))))
     (should (= 1 (length (directory-files campaign-directory nil
                                           "\\.json\\'"))))
     (should-not (file-directory-p chat-eval-directory)))))

(ert-deftest chat-coding-eval-suite-completion-keeps-state-results-intact ()
  "Completion ordering cannot destructively shorten the suite state."
  (chat-coding-eval-test-with-runtime
   (let* ((task (car (chat-coding-eval-load-suite
                      chat-coding-eval-test-manifest)))
          state completed)
     (setf (chat-coding-eval-task-judges task)
           '(((type . "no-change") (name . "unchanged"))))
     (setq state
           (chat-coding-eval-run-suite
            (list task)
            (lambda (_task _workspace done)
              (funcall done 'completed "done" nil))
            :repetitions 2
            :on-complete (lambda (results _state) (setq completed results))))
     (should (chat-coding-eval-test--wait (lambda () completed)))
     (should (= 2 (length completed)))
     (should (= 2 (length (chat-coding-eval-suite-state-results state)))))))

(ert-deftest chat-coding-eval-resume-runs-only-missing-trials ()
  "Resume validates disk state, fills missing identities and completes once."
  (chat-coding-eval-test-with-runtime
   (let* ((chat-coding-eval-campaign-directory
           (expand-file-name "campaigns/" temp-dir))
          (manifest (chat-coding-eval-test--small-manifest temp-dir))
          (campaign
           (chat-coding-eval-prepare-campaign
            "resume-001" 'provider-a "model-a" 2 manifest
            :implementation-revision "resume-revision"))
          (directory (plist-get campaign :directory))
          first-results
          (resume-calls 0))
     (chat-coding-eval--run-suite-entries
      (list (cons 1 (car (plist-get campaign :tasks))))
      (lambda (_task _workspace done)
        (funcall done 'completed "inspected" nil))
      :result-directory directory
      :result-metadata (plist-get campaign :result-metadata)
      :on-complete (lambda (results _state) (setq first-results results)))
     (should (chat-coding-eval-test--wait (lambda () first-results)))
     (should (= 1 (length first-results)))
     (cl-letf (((symbol-function 'chat-llm-provider-configured-p)
                (lambda (_provider) t))
               ((symbol-function 'chat-coding-eval-agent-executor)
                (lambda (_provider _model)
                  (lambda (_task _workspace done)
                    (cl-incf resume-calls)
                    (funcall done 'completed "inspected" nil)))))
       (chat-coding-eval-resume-live
        directory manifest "resume-revision")
       (should
        (chat-coding-eval-test--wait
         (lambda ()
           (file-exists-p (expand-file-name "completion.json" directory)))))
       (should (= 3 resume-calls))
       (should-error
        (chat-coding-eval-resume-live
         directory manifest "resume-revision")))
     (let* ((loaded (chat-coding-eval--load-campaign-results campaign))
            (results (plist-get loaded :results))
            (completion
             (chat-coding-eval--read-json-file
              (expand-file-name "completion.json" directory))))
       (should (= 4 (length results)))
       (should (= 4 (alist-get 'resultCount completion)))
       (should (eq t (alist-get 'complete completion)))
       (should (equal '(1 1 2 2)
                      (mapcar
                       (lambda (result)
                         (alist-get 'repetition
                                    (chat-eval-result-metadata result)))
                       results))))
     (should-not
      (file-exists-p (chat-coding-eval--campaign-lock-file directory))))))

(ert-deftest chat-coding-eval-resume-rejects-duplicate-trial-identity ()
  "Two durable records cannot claim the same repetition and scenario."
  (chat-coding-eval-test-with-runtime
   (let* ((chat-coding-eval-campaign-directory
           (expand-file-name "campaigns/" temp-dir))
          (manifest (chat-coding-eval-test--small-manifest temp-dir))
          (campaign
           (chat-coding-eval-prepare-campaign
            "duplicate-001" 'provider-a "model-a" 1 manifest
            :implementation-revision "resume-revision"))
          (directory (plist-get campaign :directory))
          results)
     (chat-coding-eval--run-suite-entries
      (list (cons 1 (car (plist-get campaign :tasks))))
      (lambda (_task _workspace done)
        (funcall done 'completed "inspected" nil))
      :result-directory directory
      :result-metadata (plist-get campaign :result-metadata)
      :on-complete (lambda (values _state) (setq results values)))
     (should (chat-coding-eval-test--wait (lambda () results)))
     (let* ((source (car (directory-files directory t "\\`eval-.*\\.json\\'")))
            (duplicate (chat-coding-eval--read-json-file source)))
       (setf (alist-get 'id duplicate) "eval-duplicate")
       (with-temp-file (expand-file-name "eval-duplicate.json" directory)
         (insert (json-encode duplicate))))
     (should-error (chat-coding-eval--campaign-work campaign)))))

(ert-deftest chat-coding-eval-resume-rejects-configuration-drift ()
  "Resume refuses revision, approval or manifest changes before execution."
  (chat-coding-eval-test-with-runtime
   (let* ((chat-coding-eval-campaign-directory
           (expand-file-name "campaigns/" temp-dir))
          (manifest (chat-coding-eval-test--small-manifest temp-dir))
          (campaign
           (chat-coding-eval-prepare-campaign
            "drift-001" 'provider-a "model-a" 1 manifest
            :implementation-revision "resume-revision"
            :toolchain
            '(((name . "fixture") (path . "/tools/fixture")
               (target . "/tools/fixture")
               (version . "fixture 1")))))
          (directory (plist-get campaign :directory)))
     (should-error
      (chat-coding-eval--load-open-campaign
       directory manifest "different-revision"))
     (let ((chat-coding-eval-approval-mode 'manual))
       (should-error
        (chat-coding-eval--load-open-campaign
         directory manifest "resume-revision"
         '(((name . "fixture") (path . "/tools/fixture")
            (target . "/tools/fixture")
            (version . "fixture 1"))))))
     (should-error
      (chat-coding-eval--load-open-campaign
       directory manifest "resume-revision"
       '(((name . "fixture") (path . "/tools/fixture")
          (target . "/tools/fixture")
          (version . "fixture 2")))))
     (write-region "\n" nil manifest t 'silent)
     (should-error
      (chat-coding-eval--load-open-campaign
       directory manifest "resume-revision"
       '(((name . "fixture") (path . "/tools/fixture")
          (target . "/tools/fixture")
          (version . "fixture 1"))))))))

(ert-deftest chat-coding-eval-campaign-lock-is-exclusive-and-recoverable ()
  "Only one live process may schedule missing campaign trials."
  (chat-test-with-temp-dir
   (chat-coding-eval--acquire-campaign-lock temp-dir)
   (should-error (chat-coding-eval--acquire-campaign-lock temp-dir))
   (should (chat-coding-eval--release-campaign-lock temp-dir))
   (with-temp-file (chat-coding-eval--campaign-lock-file temp-dir)
     (insert (json-encode `((pid . 99999999) (host . ,(system-name))))))
   (should (chat-coding-eval--acquire-campaign-lock temp-dir))
   (should (chat-coding-eval--release-campaign-lock temp-dir))
   (should-not
    (file-exists-p (chat-coding-eval--campaign-lock-file temp-dir)))))

(ert-deftest chat-coding-eval-cancelled-campaign-remains-resumable ()
  "Cancellation persists its current trial without terminalizing the campaign."
  (chat-coding-eval-test-with-runtime
   (let* ((chat-coding-eval-campaign-directory
           (expand-file-name "campaigns/" temp-dir))
          (manifest (chat-coding-eval-test--small-manifest temp-dir))
          (campaign
           (chat-coding-eval-prepare-campaign
            "cancel-001" 'provider-a "model-a" 1 manifest
            :implementation-revision "resume-revision"))
          (directory (plist-get campaign :directory))
          suite)
     (cl-letf (((symbol-function 'chat-llm-provider-configured-p)
                (lambda (_provider) t))
               ((symbol-function 'chat-coding-eval-agent-executor)
                (lambda (_provider _model)
                  (lambda (_task _workspace _done)
                    (chat-coding-eval-executor-handle-create
                     :cancel #'ignore
                     :snapshot (lambda () '(:metadata ((requestCount . 0)))))))))
       (setq suite
             (chat-coding-eval--start-campaign
              campaign 'provider-a "model-a"))
       (should (chat-coding-eval-cancel-suite suite))
       (should
        (chat-coding-eval-test--wait
         (lambda ()
           (not (file-exists-p
                 (chat-coding-eval--campaign-lock-file directory)))))))
     (should-not
      (file-exists-p (expand-file-name "completion.json" directory)))
     (let ((work (chat-coding-eval--campaign-work campaign)))
       (should (= 1 (length (plist-get work :results))))
       (should (= 1 (length (plist-get work :pending))))
       (should
        (eq 'cancelled
            (chat-eval-result-status
             (car (plist-get work :results)))))))))

(ert-deftest chat-coding-eval-transient-failure-pauses-without-claiming-trial ()
  "A transport outage is archived and leaves its trial resumable."
  (chat-coding-eval-test-with-runtime
   (let* ((chat-coding-eval-campaign-directory
           (expand-file-name "campaigns/" temp-dir))
          (manifest (chat-coding-eval-test--small-manifest temp-dir))
          (campaign
           (chat-coding-eval-prepare-campaign
            "transient-001" 'provider-a "model-a" 1 manifest
            :implementation-revision "transient-revision"))
          (directory (plist-get campaign :directory)))
     (cl-letf (((symbol-function 'chat-llm-provider-configured-p)
                (lambda (_provider) t))
               ((symbol-function 'chat-coding-eval-agent-executor)
                (lambda (_provider _model)
                  (lambda (_task _workspace done)
                    (funcall done 'error "" '((failureReason .
                                                "exited abnormally with code 6")))))))
       (chat-coding-eval--start-campaign campaign 'provider-a "model-a")
       (should
        (chat-coding-eval-test--wait
         (lambda ()
           (not (file-exists-p
                 (chat-coding-eval--campaign-lock-file directory)))))))
     (should-not
      (file-exists-p (expand-file-name "completion.json" directory)))
     (should (= 1 (length (directory-files
                           (expand-file-name "attempts/" directory)
                           nil "\\`eval-.*\\.json\\'"))))
     (let ((work (chat-coding-eval--campaign-work campaign)))
       (should-not (plist-get work :results))
       (should (= 2 (length (plist-get work :pending))))))))

(ert-deftest chat-coding-eval-usage-quota-pauses-without-claiming-trial ()
  "An exhausted provider quota archives one attempt and preserves all work."
  (chat-coding-eval-test-with-runtime
   (let* ((chat-coding-eval-campaign-directory
           (expand-file-name "campaigns/" temp-dir))
          (manifest (chat-coding-eval-test--small-manifest temp-dir))
          (campaign
           (chat-coding-eval-prepare-campaign
            "quota-001" 'provider-a "model-a" 1 manifest
            :implementation-revision "quota-revision"))
          (directory (plist-get campaign :directory))
          messages)
     (cl-letf (((symbol-function 'chat-llm-provider-configured-p)
                (lambda (_provider) t))
               ((symbol-function 'message)
                (lambda (format-string &rest arguments)
                  (push (apply #'format format-string arguments) messages)))
               ((symbol-function 'chat-coding-eval-agent-executor)
                (lambda (_provider _model)
                  (lambda (_task _workspace done)
                    (funcall
                     done 'error ""
                     '((failureReason .
                                      "HTTP error 403: weekly usage limit; quota exhausted")))))))
       (chat-coding-eval--start-campaign campaign 'provider-a "model-a")
       (should
        (chat-coding-eval-test--wait
         (lambda ()
           (not (file-exists-p
                 (chat-coding-eval--campaign-lock-file directory)))))))
     (should-not
      (file-exists-p (expand-file-name "completion.json" directory)))
     (should (= 1 (length (directory-files
                           (expand-file-name "attempts/" directory)
                           nil "\\`eval-.*\\.json\\'"))))
     (should (seq-some
              (lambda (text)
                (string-match-p "paused with 0 durable result" text))
              messages))
     (let ((work (chat-coding-eval--campaign-work campaign)))
       (should-not (plist-get work :results))
       (should (= 2 (length (plist-get work :pending))))))))

(ert-deftest chat-coding-eval-campaign-pause-errors-are-bounded ()
  "Campaign classification works without a historical Agent classifier."
  (cl-letf (((symbol-function 'chat-agent--transient-model-error-p) nil))
    (dolist (reason '("exited abnormally with code 16"
                      "exited abnormally with code 18"
                      "HTTP error 429: too many requests"
                      "HTTP error 503: service unavailable"
                      "provider capacity is temporarily unavailable"))
      (should
       (chat-coding-eval--transient-infrastructure-result-p
        (chat-eval-result-create-record
         :status 'error
         :metadata `((executor . ((failureReason . ,reason)))))))))
  (should-not
   (chat-coding-eval--transient-infrastructure-result-p
    (chat-eval-result-create-record
     :status 'error
     :metadata '((executor . ((failureReason . "HTTP error 403: forbidden"))))))))

(ert-deftest chat-coding-eval-rejects-unsafe-allowed-and-judge-paths ()
  "Fixture policy rejects traversal before an executor can run."
  (let* ((fixture (expand-file-name "coding-eval/python"
                                    chat-test-fixtures-dir))
         (task (chat-coding-eval-test--task
                fixture '(((type . "no-change") (name . "safe")))
                '("../outside"))))
    (should-error (chat-coding-eval--validate-task task))
    (setf (chat-coding-eval-task-allowed-paths task) '("sample.py")
          (chat-coding-eval-task-judges task)
          '(((type . "file-regexp") (name . "unsafe")
             (path . "../outside") (regexp . "x"))))
    (should-error (chat-coding-eval--validate-task task))))

(ert-deftest chat-coding-eval-rejects-unsafe-or-overlapping-generated-paths ()
  "Generated output policy cannot escape or hide an allowed source path."
  (let* ((fixture (expand-file-name "coding-eval/python"
                                    chat-test-fixtures-dir))
         (task (chat-coding-eval-test--task
                fixture '(((type . "no-change") (name . "safe"))))))
    (setf (chat-coding-eval-task-generated-paths task) '("../outside"))
    (should-error (chat-coding-eval--validate-task task))
    (setf (chat-coding-eval-task-generated-paths task) '("sample.py/cache"))
    (should-error (chat-coding-eval--validate-task task))))

(ert-deftest chat-coding-eval-read-only-run-is-traced-and-cleaned ()
  "A synchronous fake executor still enters the async result contract."
  (chat-coding-eval-test-with-runtime
   (let* ((task (seq-find
                 (lambda (item)
                   (equal "elisp-locate"
                          (chat-coding-eval-task-id item)))
                 (chat-coding-eval-load-suite
                  chat-coding-eval-test-manifest)))
          result state)
     (setq state
           (chat-coding-eval-run
            task
            (lambda (_task _workspace done)
              (funcall done 'completed
                       "sample-find-user reports a missing user"
                       '((model . "fake"))))
            :on-complete (lambda (value _state) (setq result value))))
     (should result)
     (should (eq 'passed (chat-eval-result-status result)))
     (should-not (file-exists-p
                  (chat-coding-eval-run-state-workspace state)))
     (should (file-exists-p
              (chat-eval--result-file (chat-eval-result-id result)))))))

(ert-deftest chat-coding-eval-executor-metadata-is-redacted-on-disk ()
  "Provider metadata uses the evaluation privacy boundary."
  (chat-coding-eval-test-with-runtime
   (let* ((task (car (chat-coding-eval-load-suite
                      chat-coding-eval-test-manifest)))
          result)
     (setf (chat-coding-eval-task-judges task)
           '(((type . "no-change") (name . "unchanged"))))
     (chat-coding-eval-run
      task
      (lambda (_task _workspace done)
        (funcall done 'completed "done"
                 '((providerDetail . "token=abcdefghijklmnop"))))
      :on-complete (lambda (value _state) (setq result value)))
     (let ((json (with-temp-buffer
                   (insert-file-contents
                    (chat-eval--result-file (chat-eval-result-id result)))
                   (buffer-string))))
       (should (string-match-p "redacted" json))
       (should-not (string-match-p "abcdefghijklmnop" json))))))

(ert-deftest chat-coding-eval-command-judge-accepts-an-allowed-fix ()
  "An allowed edit is tested by argv without invoking a shell."
  (chat-coding-eval-test-with-runtime
   (let* ((task (seq-find
                 (lambda (item)
                   (equal "python-single-fix"
                          (chat-coding-eval-task-id item)))
                 (chat-coding-eval-load-suite
                  chat-coding-eval-test-manifest)))
          result)
     (chat-coding-eval-run
      task
      (lambda (_task workspace done)
        (let ((file (expand-file-name "sample.py" workspace)))
          (with-temp-buffer
            (insert-file-contents file)
            (goto-char (point-min))
            (re-search-forward
             "def divide(left, right):\n    return left // right")
            (replace-match
             "def divide(left, right):\n    if right == 0:\n        raise ValueError(\"zero divisor\")\n    return left / right"
             t t)
            (write-region (point-min) (point-max) file nil 'silent)))
        (funcall done 'completed "fixed" nil)
        nil)
      :on-complete (lambda (value _state) (setq result value)))
     (should (chat-coding-eval-test--wait (lambda () result) 5))
     (should (eq 'passed (chat-eval-result-status result)))
     (should (equal '("sample.py")
                    (alist-get 'changedFiles
                               (chat-eval-result-metadata result)))))))

(ert-deftest chat-coding-eval-fails-closed-on-out-of-scope-change ()
  "Unexpected changed paths fail before untrusted judge commands run."
  (chat-coding-eval-test-with-runtime
   (let* ((fixture (expand-file-name "coding-eval/python"
                                     chat-test-fixtures-dir))
          (task (chat-coding-eval-test--task
                 fixture '(((type . "no-change") (name . "unchanged")))))
          result)
     (chat-coding-eval-run
      task
      (lambda (_task workspace done)
        (write-region "outside" nil
                      (expand-file-name "unexpected.txt" workspace)
                      nil 'silent)
        (funcall done 'completed "done" nil))
      :on-complete (lambda (value _state) (setq result value)))
     (should result)
     (should (eq 'failed (chat-eval-result-status result)))
     (should (equal '("unexpected.txt")
                    (alist-get 'outOfScopeFiles
                               (chat-eval-result-metadata result)))))))

(ert-deftest chat-coding-eval-separates-declared-build-artifacts-from-source ()
  "Declared build outputs are audited without becoming source scope failures."
  (chat-coding-eval-test-with-runtime
   (let* ((fixture (expand-file-name "coding-eval/python"
                                     chat-test-fixtures-dir))
          (task (chat-coding-eval-test--task
                 fixture '(((type . "file-regexp") (name . "fixed")
                            (path . "sample.py") (regexp . "fixed")))))
          result)
     (setf (chat-coding-eval-task-generated-paths task)
           '("build" "generated.lock"))
     (chat-coding-eval-run
      task
      (lambda (_task workspace done)
        (write-region "fixed\n" nil (expand-file-name "sample.py" workspace)
                      nil 'silent)
        (make-directory (expand-file-name "build/cache" workspace) t)
        (write-region "artifact" nil
                      (expand-file-name "build/cache/output" workspace)
                      nil 'silent)
        (write-region "lock" nil
                      (expand-file-name "generated.lock" workspace)
                      nil 'silent)
        (funcall done 'completed "done" nil))
      :on-complete (lambda (value _state) (setq result value)))
     (should result)
     (should (eq 'passed (chat-eval-result-status result)))
     (should (equal '("build/cache/output" "generated.lock")
                    (alist-get 'generatedFiles
                               (chat-eval-result-metadata result))))
     (should-not (alist-get 'outOfScopeFiles
                            (chat-eval-result-metadata result))))))

(ert-deftest chat-coding-eval-records-crash-cancel-and-timeout ()
  "Every executor terminal path produces evidence and removes its workspace."
  (chat-coding-eval-test-with-runtime
   (let* ((fixture (expand-file-name "coding-eval/python"
                                     chat-test-fixtures-dir))
          (judges '(((type . "no-change") (name . "unchanged"))))
          (task (chat-coding-eval-test--task fixture judges))
          crash-result cancel-result timeout-result cancel-called
          timeout-cancel-called)
     (chat-coding-eval-run
      task (lambda (&rest _args) (error "executor crashed"))
      :on-complete (lambda (value _state) (setq crash-result value)))
     (should (eq 'error (chat-eval-result-status crash-result)))
     (let ((state
            (chat-coding-eval-run
             task
             (lambda (_task _workspace done)
               (chat-coding-eval-executor-handle-create
                :cancel
                (lambda ()
                  (setq cancel-called t)
                  (funcall done 'cancelled "late" '((late . t))))
                :snapshot
                (lambda ()
                  '(:answer "partial"
                    :metadata ((requestCount . 1)
                               (requestModels . (((provider . "fixture")
                                                  (model . "model")
                                                  (requestId . "request-1")))))))))
             :on-complete (lambda (value _state) (setq cancel-result value)))))
       (should (chat-coding-eval-cancel state)))
     (should cancel-called)
     (should (eq 'cancelled (chat-eval-result-status cancel-result)))
     (should (= 1 (alist-get 'requestCount
                             (alist-get 'executor
                                        (chat-eval-result-metadata
                                         cancel-result)))))
     (setf (chat-coding-eval-task-timeout-seconds task) 0.03)
     (chat-coding-eval-run
      task
      (lambda (_task _workspace done)
        (chat-coding-eval-executor-handle-create
         :cancel
         (lambda ()
           (setq timeout-cancel-called t)
           (funcall done 'cancelled "late" '((late . t))))
         :snapshot
         (lambda ()
           '(:metadata ((requestCount . 2)
                        (requestModels . (((provider . "fixture")
                                           (model . "model")
                                           (requestId . "request-1"))
                                          ((provider . "fixture")
                                           (model . "model")
                                           (requestId . "request-2")))))))))
      :on-complete (lambda (value _state) (setq timeout-result value)))
     (should (chat-coding-eval-test--wait (lambda () timeout-result)))
     (should timeout-cancel-called)
     (should (eq 'timed-out (chat-eval-result-status timeout-result)))
     (should (= 2 (alist-get 'requestCount
                             (alist-get 'executor
                                        (chat-eval-result-metadata
                                         timeout-result)))))
     (should-not
      (directory-files chat-coding-eval-workspace-directory nil "test-task-")))))

(ert-deftest chat-coding-eval-command-timeout-kills-the-process ()
  "A stalled judge is terminated and cannot survive workspace cleanup."
  (chat-coding-eval-test-with-runtime
   (let* ((fixture (expand-file-name "coding-eval/python"
                                     chat-test-fixtures-dir))
          (task
           (chat-coding-eval-test--task
            fixture
            '(((type . "command") (name . "stall")
               (command . ["python3" "-c" "import time; time.sleep(1)"])
               (expectedExit . 0) (timeoutSeconds . 0.03)))))
          result state process)
     ;; JSON commands decode as lists; normalize this direct fixture too.
     (setcdr (assq 'command (car (chat-coding-eval-task-judges task)))
             '("python3" "-c" "import time; time.sleep(1)"))
     (setq state
           (chat-coding-eval-run
            task
            (lambda (_task _workspace done)
              (funcall done 'completed "done" nil)
              nil)
            :on-complete (lambda (value _state) (setq result value))))
     (setq process (chat-coding-eval-run-state-process state))
     (should (chat-coding-eval-test--wait (lambda () result)))
     (should (eq 'timed-out (chat-eval-result-status result)))
     (should-not (process-live-p process))
     (should-not (file-exists-p
                  (chat-coding-eval-run-state-workspace state))))))

(ert-deftest chat-coding-eval-missing-command-judge-finishes-with-error ()
  "A missing judge executable records evidence instead of hanging forever."
  (chat-coding-eval-test-with-runtime
   (let* ((fixture (expand-file-name "coding-eval/python"
                                     chat-test-fixtures-dir))
          (command '("chat-coding-eval-command-that-does-not-exist"))
          (task
           (chat-coding-eval-test--task
            fixture
            `(((type . "command") (name . "missing-command")
               (command . ,command) (expectedExit . 0)))))
          result state)
     (setq state
           (chat-coding-eval-run
            task
            (lambda (_task _workspace done)
              (funcall done 'completed "done" nil))
            :on-complete (lambda (value _state) (setq result value))))
     (should result)
     (should (eq 'error (chat-eval-result-status result)))
     (let ((check
            (seq-find
             (lambda (item)
               (equal "missing-command" (chat-eval-check-name item)))
             (chat-eval-result-checks result))))
       (should check)
       (should (equal "not-started"
                      (alist-get 'status (chat-eval-check-actual check))))
       (should (equal command
                      (alist-get 'command (chat-eval-check-actual check))))
       (should (string-match-p "could not start"
                               (chat-eval-check-detail check))))
     (should-not (file-exists-p
                  (chat-coding-eval-run-state-workspace state))))))

(ert-deftest chat-coding-eval-post-processing-error-finishes-with-evidence ()
  "A synchronous completion error cannot outlive the cancelled task timer."
  (chat-coding-eval-test-with-runtime
   (let* ((fixture (expand-file-name "coding-eval/python"
                                     chat-test-fixtures-dir))
          (task
           (chat-coding-eval-test--task
            fixture '(((type . "no-change") (name . "unchanged")))))
          (original-snapshot (symbol-function 'chat-coding-eval--snapshot))
          (snapshot-count 0)
          result state)
     (cl-letf (((symbol-function 'chat-coding-eval--snapshot)
                (lambda (directory)
                  (cl-incf snapshot-count)
                  (if (= snapshot-count 1)
                      (funcall original-snapshot directory)
                    (error "synthetic snapshot failure")))))
       (setq state
             (chat-coding-eval-run
              task
              (lambda (_task _workspace done)
                (funcall done 'completed "done" nil))
              :on-complete (lambda (value _state) (setq result value)))))
     (should result)
     (should (eq 'error (chat-eval-result-status result)))
     (should
      (seq-find
       (lambda (check)
         (and (equal "evaluator-post-processing" (chat-eval-check-name check))
              (string-match-p "synthetic snapshot failure"
                              (chat-eval-check-detail check))))
       (chat-eval-result-checks result)))
     (should-not (file-exists-p
                  (chat-coding-eval-run-state-workspace state))))))

(provide 'test-chat-coding-eval)
;;; test-chat-coding-eval.el ends here
