;;; test-chat-code-verify.el --- Verification contract tests -*- lexical-binding: t -*-

(require 'ert)
(require 'test-helper)
(require 'chat-code-verify)

(defun chat-code-verify-test--step (kind &optional required)
  "Return a minimal verification step of KIND."
  (chat-verification-step-create
   :id (symbol-name kind) :kind kind :argv (list "verify" (symbol-name kind))
   :directory default-directory :timeout-seconds 5 :max-output-bytes 128
   :trigger 'changed :required-p required :approval-class 'inspect))

(defun chat-code-verify-test--profile (&rest steps)
  "Return a temporary verification profile containing STEPS."
  (chat-verification-profile-create
   :id "test-profile"
   :project-root (or (and steps
                          (chat-verification-step-directory (car steps)))
                     default-directory)
   :source 'test
   :revision "test" :steps steps :repair-limit 2))

(defun chat-code-verify-test--install-execution-backends ()
  "Install local plus a deterministic restricted backend test double."
  (chat-execution-install-local-backend)
  (chat-execution-register-backend
   (chat-execution-backend-create
    :id 'darwin-sandbox
    :capabilities
    (chat-execution-capabilities-create
     :filesystem 'scoped :network 'controlled :environment 'explicit
     :timeout t :process-tree-cleanup t :platform 'test
     :availability "available")
    :start-function #'chat-execution--local-start
    :cancel-function #'chat-execution--local-cancel
    :live-p-function #'chat-execution--local-live-p)))

(ert-deftest chat-code-verify-contract-rejects-shell-and-invalid-status ()
  "Verification commands are argv-only and result statuses are closed."
  (should-error
   (chat-code-verify-validate-step
    (chat-verification-step-create
     :id "bad" :kind 'test :argv "bash -c false")))
  (should-error
   (chat-code-verify-result-create :id "bad" :status 'successful))
  (dolist (status '(passed failed cancelled timed-out not-run blocked))
    (should (chat-code-verification-status-p status))))

(ert-deftest chat-code-verify-detects-manifest-commands-deterministically ()
  "Manifest detection yields ordered argv without installing anything."
  (chat-test-with-temp-dir
   (with-temp-file (expand-file-name "package.json" temp-dir)
     (insert "{\"scripts\":{\"build\":\"x\",\"test\":\"x\",\"lint\":\"x\",\"typecheck\":\"x\"}}"))
   (let* ((first (chat-code-verify-plan temp-dir '("src/a.ts")))
          (second (chat-code-verify-plan temp-dir '("src/a.ts")))
          (steps (chat-verification-profile-steps first)))
     (should (equal (mapcar #'chat-verification-step-kind steps)
                    '(lint typecheck test build)))
     (should (equal (mapcar #'chat-verification-step-argv steps)
                    (mapcar #'chat-verification-step-argv
                            (chat-verification-profile-steps second))))
     (should (cl-every (lambda (step)
                         (cl-every #'stringp
                                   (chat-verification-step-argv step)))
                       steps)))))

(ert-deftest chat-code-verify-prefers-exact-runtime-contract ()
  "A trusted task command outranks project and detected verification policy."
  (chat-test-with-temp-dir
   (with-temp-file (expand-file-name "test.js" temp-dir)
     (insert ""))
   (with-temp-file (expand-file-name ".chat-verification.json" temp-dir)
     (insert
      "{\"id\":\"project\",\"steps\":[{\"id\":\"generic\","
      "\"kind\":\"test\",\"argv\":[\"node\",\"test.js\"],"
      "\"required\":true}]}"))
   (let* ((profile
           (chat-code-verify-plan
            temp-dir nil
            '(:verification-commands (("node" "test.js" "normalize")))))
          (steps (chat-verification-profile-steps profile))
          (step (car steps)))
     (should (eq (chat-verification-profile-source profile)
                 'runtime-contract))
     (should (= (length steps) 1))
     (should (equal (chat-verification-step-argv step)
                    '("node" "test.js" "normalize")))
     (should (chat-verification-step-required-p step))
     (should (eq (chat-verification-step-trigger step) 'always))
     (should (equal (file-name-as-directory (file-truename temp-dir))
                    (chat-verification-step-directory step))))))

(ert-deftest chat-code-verify-rejects-malformed-runtime-contract-context ()
  "An internal caller cannot smuggle unbounded or empty argv into a profile."
  (chat-test-with-temp-dir
   (should-error
    (chat-code-verify-plan
     temp-dir nil '(:verification-commands (("node" "")))))))

(ert-deftest chat-code-verify-detects-conventional-language-tests ()
  "Conventional small projects get argv-only checks without project config."
  (dolist (case '(("test_sample.py" . ("python3" "-m" "unittest"))
                  ("test.js" . ("node" "test.js"))
                  ("sample-test.el" . ("emacs" "-Q" "--batch" "-L" "."
                                        "-l" "sample-test.el" "--eval"
                                        "(ert-run-tests-batch-and-exit)"))))
    (chat-test-with-temp-dir
     (with-temp-file (expand-file-name (car case) temp-dir)
       (insert ""))
     (let* ((profile (chat-code-verify-plan temp-dir nil))
            (steps (chat-verification-profile-steps profile)))
       (should (= (length steps) 1))
       (should (equal (chat-verification-step-argv (car steps))
                      (cdr case)))))))

(ert-deftest chat-code-verify-composes-multiple-language-ecosystems ()
  "A polyglot repository keeps checks for every detected ecosystem."
  (chat-test-with-temp-dir
   (with-temp-file (expand-file-name "go.mod" temp-dir)
     (insert "module example.test/polyglot\n"))
   (with-temp-file (expand-file-name "test_sample.py" temp-dir)
     (insert ""))
   (let* ((profile (chat-code-verify-plan temp-dir nil))
          (steps (chat-verification-profile-steps profile)))
     (should (equal (mapcar #'chat-verification-step-id steps)
                    '("go-test" "python-test" "go-build"))))))

(ert-deftest chat-code-verify-keeps-conventional-javascript-steps-distinct ()
  "Multiple conventional JavaScript entrypoints retain stable identities."
  (chat-test-with-temp-dir
   (dolist (name '("test.js" "test.mjs"))
     (with-temp-file (expand-file-name name temp-dir)
       (insert "")))
   (let* ((profile (chat-code-verify-plan temp-dir nil))
          (steps (chat-verification-profile-steps profile)))
     (should (equal (mapcar #'chat-verification-step-id steps)
                    '("javascript-test-js" "javascript-test-mjs")))
     (should (equal (mapcar #'chat-verification-step-argv steps)
                    '(("node" "test.js") ("node" "test.mjs")))))))

(ert-deftest chat-code-verify-detects-authoritative-extended-language-checks ()
  "Extended ecosystems produce checks only from authoritative markers."
  (dolist
      (case
       `(("build.zig"
          "pub fn build(b: *std.Build) void { _ = b.step(\"test\", \"Run\"); }"
          "zig-test" ("zig" "build" "test"))
         ("project.clj" "(defproject sample \"0\")"
          "clojure-test" ("lein" "test"))
         ("pom.xml" "<project/>"
          "java-maven-test" ("mvn" "-o" "test"))
         ("tsconfig.json" "{}"
          "typescript-typecheck" ("tsc" "--noEmit" "--project" "tsconfig.json"))
         ("Makefile" "test:\n\t@true\n"
          "make-test" ("make" "test"))))
    (chat-test-with-temp-dir
     (with-temp-file (expand-file-name (nth 0 case) temp-dir)
       (insert (nth 1 case)))
     (let* ((profile (chat-code-verify-plan temp-dir nil))
            (steps (chat-verification-profile-steps profile)))
       (should (= (length steps) 1))
       (should (equal (chat-verification-step-id (car steps)) (nth 2 case)))
       (should (equal (chat-verification-step-argv (car steps)) (nth 3 case)))))))

(ert-deftest chat-code-verify-prefers-project-local-typescript-compiler ()
  "TypeScript verification uses the project's executable compiler when present."
  (chat-test-with-temp-dir
   (let ((compiler (expand-file-name "node_modules/.bin/tsc" temp-dir)))
     (make-directory (file-name-directory compiler) t)
     (with-temp-file compiler (insert "#!/bin/sh\nexit 0\n"))
     (set-file-modes compiler #o755)
     (with-temp-file (expand-file-name "tsconfig.json" temp-dir)
       (insert "{}"))
     (let* ((profile (chat-code-verify-plan temp-dir nil))
            (step (car (chat-verification-profile-steps profile))))
       (should (equal (chat-verification-step-argv step)
                      (list (file-truename compiler)
                            "--noEmit" "--project" "tsconfig.json")))))))

(ert-deftest chat-code-verify-prefers-checked-in-java-wrapper ()
  "Java verification uses the checked-in offline wrapper before global tools."
  (chat-test-with-temp-dir
   (let ((wrapper (expand-file-name "gradlew" temp-dir)))
     (make-directory (expand-file-name "gradle/wrapper" temp-dir) t)
     (with-temp-file wrapper (insert "#!/bin/sh\nexit 0\n"))
     (set-file-modes wrapper #o755)
     (with-temp-file (expand-file-name "build.gradle.kts" temp-dir)
       (insert "plugins { java }"))
     (with-temp-file
         (expand-file-name "gradle/wrapper/gradle-wrapper.properties" temp-dir)
       (insert "distributionUrl=local"))
     (let* ((profile (chat-code-verify-plan temp-dir nil))
            (step (car (chat-verification-profile-steps profile))))
       (should (equal (chat-verification-step-argv step)
                      (list (file-truename wrapper) "--offline" "test")))))))

(ert-deftest chat-code-verify-project-config-overrides-language-detection ()
  "Explicit project policy remains authoritative over language adapters."
  (chat-test-with-temp-dir
   (with-temp-file (expand-file-name "build.zig" temp-dir)
     (insert "pub fn build(b: *std.Build) void { _ = b.step(\"test\", \"Run\"); }"))
   (with-temp-file (expand-file-name ".chat-verification.json" temp-dir)
     (insert
      "{\"id\":\"explicit\",\"steps\":[{\"id\":\"chosen\",\"kind\":\"test\",\"argv\":[\"verify\"],\"required\":true}]}"))
   (let* ((profile (chat-code-verify-plan temp-dir nil))
          (steps (chat-verification-profile-steps profile)))
     (should (eq (chat-verification-profile-source profile) 'project-config))
     (should (equal (mapcar #'chat-verification-step-id steps) '("chosen"))))))

(ert-deftest chat-code-verify-does-not-duplicate-package-typecheck ()
  "A package typecheck script remains the sole TypeScript authority."
  (chat-test-with-temp-dir
   (with-temp-file (expand-file-name "package.json" temp-dir)
     (insert "{\"scripts\":{\"typecheck\":\"tsc --noEmit\"}}"))
   (with-temp-file (expand-file-name "tsconfig.json" temp-dir)
     (insert "{}"))
   (let* ((profile (chat-code-verify-plan temp-dir '("src/a.ts")))
          (steps (chat-verification-profile-steps profile)))
     (should (equal (mapcar #'chat-verification-step-id steps)
                    '("javascript-typecheck"))))))

(ert-deftest chat-code-verify-refuses-ambiguous-extended-language-markers ()
  "A source suffix or incomplete build marker never invents a verifier."
  (dolist (files '(("build.zig" . "pub fn build(_: *std.Build) void {}")
                   ("deps.edn" . "{:aliases {:test {:extra-paths [\"test\"]}}}")
                   ("build.gradle" . "plugins { id 'java' }")
                   ("main.c" . "int main(void) { return 0; }")
                   ("query.sql" . "select 1;")
                   ("Makefile" . "build:\n\t@true\n")))
    (chat-test-with-temp-dir
     (with-temp-file (expand-file-name (car files) temp-dir)
       (insert (cdr files)))
     (should-not
      (chat-verification-profile-steps
       (chat-code-verify-plan temp-dir (list (car files))))))))

(ert-deftest chat-code-verify-rejects-duplicate-step-identities ()
  "Polyglot profile composition cannot create ambiguous result identities."
  (chat-test-with-temp-dir
   (let ((left (chat-code-verify-test--step 'test t))
         (right (chat-code-verify-test--step 'test t)))
     (should-error
      (chat-code-verify-validate-profile
       (chat-code-verify-test--profile left right))))))

(ert-deftest chat-code-verify-unrecognized-project-is-not-run ()
  "No recognizable command never becomes a false pass."
  (chat-test-with-temp-dir
   (let* ((profile (chat-code-verify-plan temp-dir nil))
          (result (chat-code-verify-run-sync profile)))
     (should (null (chat-verification-profile-steps profile)))
     (should (eq (chat-code-verify-result-status result) 'not-run)))))

(ert-deftest chat-code-verify-spawns-a-distinct-child-of-the-agent-task ()
  "Verification must not replace its running Agent correlation task."
  (chat-test-with-temp-dir
   (let ((chat-task-directory (expand-file-name "tasks/" chat-state-dir))
         (chat-task--registry (make-hash-table :test 'equal))
         (chat-task--loaded-p t))
     (let* ((agent-task
             (chat-task-adopt
              :id "agent-task" :kind 'agent :title "Agent run"
              :status 'running :session-id "session" :source 'agent))
            (profile (chat-code-verify-plan temp-dir nil))
            (result
             (chat-code-verify-run-sync
              profile '(:session-id "session" :turn-id 1
                        :task-id "agent-task" :run-id "run")))
            (verification-task
             (chat-task-get (chat-code-verify-result-task-id result))))
       (should (eq (chat-code-verify-result-status result) 'not-run))
       (should-not (equal (chat-code-verify-result-task-id result)
                          "agent-task"))
       (should (equal (chat-code-verify-result-parent-task-id result)
                      "agent-task"))
       (should (eq (chat-task-status agent-task) 'running))
       (should (eq (chat-task-status verification-task) 'completed))
       (should (equal (chat-task-parent-id verification-task) "agent-task"))))))

(ert-deftest chat-code-verify-runtime-evidence-correlates-task-execution-and-wire ()
  "A real check is traceable through all existing runtime authorities."
  (chat-test-with-temp-dir
   (let ((chat-execution-directory (expand-file-name "executions/" chat-state-dir))
         (chat-task-directory (expand-file-name "tasks/" chat-state-dir))
         (chat-execution--records (make-hash-table :test 'equal))
         (chat-execution--backends (make-hash-table :test 'eq))
         (chat-task--registry (make-hash-table :test 'equal))
         (chat-task--loaded-p t)
         (chat-session-wire--sequences (make-hash-table :test 'equal))
         (chat-session-wire--sizes (make-hash-table :test 'equal)))
     (chat-code-verify-test--install-execution-backends)
     (let* ((step (chat-verification-step-create
                   :id "test" :kind 'test
                   :argv (list invocation-name "-Q" "--batch"
                               "--eval" "(kill-emacs 0)")
                   :directory temp-dir :timeout-seconds 5
                   :max-output-bytes 1024 :trigger 'changed
                   :required-p t :approval-class 'inspect))
            (profile (chat-code-verify-test--profile step))
            (result (chat-code-verify-run-sync
                     profile '(:session-id "verify-session")))
            (item (car (chat-code-verify-result-step-results result)))
            (task (chat-task-get (chat-code-verify-result-task-id result))))
       (should (eq (chat-code-verify-result-status result) 'passed))
       (should task)
       (should (eq (chat-task-status task) 'completed))
       (should (chat-verification-step-result-execution-id item))
       (should (chat-execution-get
                (chat-verification-step-result-execution-id item)))
       (with-temp-buffer
         (insert-file-contents (chat-session-wire-file "verify-session"))
         (should (search-forward "verification-step-started" nil t))
         (should (search-forward "verification-step-completed" nil t))
         (should (search-forward "verification-completed" nil t)))
       (let ((id (chat-code-verify-result-id result)))
         (clrhash chat-code-verify--results)
         (clrhash chat-task--registry)
         (setq chat-task--loaded-p nil)
         (should (eq (chat-code-verify-result-status
                      (chat-code-verify-get id))
                     'passed)))))))

(ert-deftest chat-code-verify-required-failures-never-pass ()
  "Every seeded verification kind fails the overall result when required."
  (dolist (kind '(format lint typecheck test build))
    (let* ((profile (chat-code-verify-test--profile
                     (chat-code-verify-test--step kind t)))
           (chat-code-verify-executor
            (lambda (_step _context callback)
              (funcall callback
                       (list :status 'failed :exit-code 1
                             :output (format "%s failed" kind)))))
           (result (chat-code-verify-run-sync profile)))
      (should (eq (chat-code-verify-result-status result) 'failed))
      (should (eq (chat-verification-step-result-kind
                   (car (chat-code-verify-result-step-results result)))
                  kind)))))

(ert-deftest chat-code-verify-classifies-runtime-terminal-states ()
  "Blocked, timeout, cancellation and output limits remain explicit."
  (dolist (pair '((blocked . blocked)
                  (timed-out . timed-out)
                  (cancelled . cancelled)
                  (output-limit . failed)))
    (let* ((profile (chat-code-verify-test--profile
                     (chat-code-verify-test--step 'test t)))
           (chat-code-verify-executor
            (lambda (_step _context callback)
              (funcall callback
                       (list :status (car pair) :reason (symbol-name (car pair))))))
           (result (chat-code-verify-run-sync profile)))
      (should (eq (chat-code-verify-result-status result) (cdr pair))))))

(ert-deftest chat-code-verify-default-executor-bounds-runtime-failures ()
  "The execution adapter enforces missing command, timeout, and output limits."
  (chat-test-with-temp-dir
   (let ((chat-execution-directory (expand-file-name "executions/" chat-state-dir))
         (chat-execution--records (make-hash-table :test 'equal))
         (chat-execution--backends (make-hash-table :test 'eq)))
     (chat-code-verify-test--install-execution-backends)
     (cl-labels
         ((run (argv timeout limit)
            (let ((chat-code-verify-executor #'chat-code-verify--execute-step))
              (chat-code-verify-run-sync
               (chat-code-verify-test--profile
                (chat-verification-step-create
                 :id "test" :kind 'test :argv argv :directory temp-dir
                 :timeout-seconds timeout :max-output-bytes limit
                 :trigger 'changed :required-p t :approval-class 'inspect))))))
       (should (eq (chat-code-verify-result-status
                    (run '("chat-command-that-does-not-exist") 1 128))
                   'blocked))
       (should (eq (chat-code-verify-result-status
                    (run (list invocation-name "-Q" "--batch" "--eval"
                               "(sleep-for 2)")
                         0.05 128))
                   'timed-out))
       (let* ((result
               (run (list invocation-name "-Q" "--batch" "--eval"
                          "(princ (make-string 4096 ?x))")
                    2 64))
              (item (car (chat-code-verify-result-step-results result))))
         (should (eq (chat-code-verify-result-status result) 'failed))
         (should (equal (chat-verification-step-result-reason item)
                        "output-limit")))))))

(ert-deftest chat-code-verify-cancellation-closes-the-live-execution ()
  "Cancellation becomes an explicit result and leaves no live execution."
  (chat-test-with-temp-dir
   (let ((chat-execution-directory (expand-file-name "executions/" chat-state-dir))
         (chat-execution--records (make-hash-table :test 'equal))
         (chat-execution--backends (make-hash-table :test 'eq))
         (chat-code-verify-executor #'chat-code-verify--execute-step)
         result)
     (chat-code-verify-test--install-execution-backends)
     (let* ((profile
             (chat-code-verify-test--profile
              (chat-verification-step-create
               :id "test" :kind 'test
               :argv (list invocation-name "-Q" "--batch" "--eval"
                           "(sleep-for 2)")
               :directory temp-dir :timeout-seconds 2 :max-output-bytes 128
               :trigger 'changed :required-p t :approval-class 'inspect)))
            (handle (chat-code-verify-run
                     profile :on-complete (lambda (value) (setq result value)))))
       (funcall (plist-get handle :cancel))
       (while (null result) (accept-process-output nil 0.01))
       (should (eq (chat-code-verify-result-status result) 'cancelled))
       (should-not (seq-some #'chat-execution-live-p
                             (chat-execution-list)))))))

(ert-deftest chat-code-verify-fingerprints-preexisting-failures ()
  "Preflight fingerprints distinguish old and introduced failures."
  (let* ((old (chat-code-verify-failure-fingerprint
               'test 1 "old failure\nline 2"))
         (same (chat-code-verify-classify-failure old (list old)))
         (new (chat-code-verify-classify-failure
               (chat-code-verify-failure-fingerprint 'test 1 "new failure")
               (list old))))
    (should (eq same 'pre-existing))
    (should (eq new 'introduced))))

(ert-deftest chat-code-verify-repair-passes-after-one-new-diff ()
  "One repair can replace failure evidence with a passing rerun."
  (let ((attempt 0)
        (repairs 0)
        final)
    (let ((chat-code-verify-executor
           (lambda (_step _context callback)
             (cl-incf attempt)
             (funcall callback
                      (if (= attempt 1)
                          '(:status failed :exit-code 1 :output "first")
                        '(:status passed :exit-code 0 :output "ok"))))))
      (chat-code-verify-run-with-repair
       (chat-code-verify-test--profile
        (chat-code-verify-test--step 'test t))
       (lambda (_feedback _round done)
         (cl-incf repairs)
         (funcall done '(:changed-files ("src/a.el") :diff-digest "new")))
       :allowed-paths '("src/a.el")
       :on-complete (lambda (result) (setq final result))))
    (should (eq (chat-code-verify-result-status final) 'passed))
    (should (= repairs 1))
    (should (= (chat-code-verify-result-repair-round final) 1))))

(ert-deftest chat-code-verify-repair-stops-on-identical-failure ()
  "An unchanged failure fingerprint terminates before the repair budget."
  (let ((repairs 0)
        final)
    (let ((chat-code-verify-executor
           (lambda (_step _context callback)
             (funcall callback
                      '(:status failed :exit-code 1 :output "same")))))
      (chat-code-verify-run-with-repair
       (chat-code-verify-test--profile
        (chat-code-verify-test--step 'test t))
       (lambda (_feedback _round done)
         (cl-incf repairs)
         (funcall done '(:changed-files ("src/a.el") :diff-digest "new")))
       :allowed-paths '("src/a.el")
       :on-complete (lambda (result) (setq final result))))
    (should (eq (chat-code-verify-result-status final) 'failed))
    (should (= repairs 1))
    (should (equal (chat-code-verify-result-stop-reason final)
                   "unchanged-failure"))))

(ert-deftest chat-code-verify-repair-rejects-unrelated-files ()
  "Repair changes outside the owned set are rejected and rolled back."
  (let ((rolled-back nil)
        final
        (chat-code-verify-executor
         (lambda (_step _context callback)
           (funcall callback '(:status failed :exit-code 1 :output "bad")))))
    (chat-code-verify-run-with-repair
     (chat-code-verify-test--profile
      (chat-code-verify-test--step 'test t))
     (lambda (_feedback _round done)
       (funcall done '(:changed-files ("other.txt") :diff-digest "outside")))
     :allowed-paths '("src/a.el")
     :rollback-function (lambda () (setq rolled-back t))
     :on-complete (lambda (result) (setq final result)))
    (should rolled-back)
    (should (eq (chat-code-verify-result-status final) 'blocked))
    (should (equal (chat-code-verify-result-stop-reason final)
                   "repair-outside-allowed-paths"))))

(ert-deftest chat-code-verify-live-summary-never-loads-durable-tasks ()
  "Final-answer projection only consults this process's current-turn facts."
  (let* ((chat-code-verify--results (make-hash-table :test 'equal))
         (older (chat-code-verify-result-create
                 :id "older" :status 'failed :session-id "session"
                 :turn-id 3 :created-at 10))
         (newer (chat-code-verify-result-create
                 :id "newer" :status 'passed :session-id "session"
                 :turn-id 3 :created-at 20)))
    (puthash "older" older chat-code-verify--results)
    (puthash "newer" newer chat-code-verify--results)
    (cl-letf (((symbol-function 'chat-task-list)
               (lambda () (ert-fail "live lookup touched durable tasks"))))
      (should (eq (chat-code-verify-latest-for-session "session" 3) newer))
      (should-not (chat-code-verify-latest-for-session "session" 4)))))

(ert-deftest chat-code-verify-plans-have-unique-scoped-runtime-identities ()
  "Each resolved plan is an opaque handle owned by its session and Agent task."
  (chat-test-with-temp-dir
   (let ((chat-code-verify--profiles (make-hash-table :test 'equal))
         (chat-code-verify--profile-contexts (make-hash-table :test 'equal)))
     (with-temp-file (expand-file-name ".chat-verification.json" temp-dir)
       (insert
        "{\"id\":\"project\",\"steps\":[{\"id\":\"test\","
        "\"kind\":\"test\",\"argv\":[\"sh\",\"test-one\",\"active\"],"
        "\"required\":true}]}"))
     (let ((first (chat-code-verify-plan
                   temp-dir nil '(:session-id "session-a" :task-id "task-a")))
           (second (chat-code-verify-plan
                    temp-dir nil '(:session-id "session-b" :task-id "task-b"))))
       (should-not (equal (chat-verification-profile-id first)
                          (chat-verification-profile-id second)))
       (should (eq first
                   (chat-code-verify-latest-profile-for-context
                    "session-a" "task-a")))
       (should (eq second
                   (chat-code-verify-latest-profile-for-context
                    "session-b" "task-b")))
       (should-not
        (chat-code-verify-profile-owned-p
         (chat-verification-profile-id first) "session-b" "task-b"))))))

(provide 'test-chat-code-verify)
;;; test-chat-code-verify.el ends here
