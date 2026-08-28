;;; test-chat-coding-eval.el --- Coding evaluation tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'test-helper)
(require 'chat-coding-eval)

(defconst chat-coding-eval-test-manifest
  (expand-file-name "coding-eval/manifest.json" chat-test-fixtures-dir))

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
   (let* ((task (chat-coding-eval-test--task temp-dir nil))
          config metadata)
     (cl-letf (((symbol-function 'chat-agent-start)
                (lambda (value) (setq config value) nil)))
       (funcall (chat-coding-eval-agent-executor 'eval-provider "model")
                task temp-dir
                (lambda (_status _content value) (setq metadata value))))
     (let ((session (plist-get config :session))
           (on-event (plist-get config :on-event)))
       (should (chat-code-session-p session))
       (should (equal (file-name-as-directory temp-dir)
                      (file-name-as-directory
                       (chat-code-session-project-root session))))
       (funcall on-event
                '(:type tool-event
                  :event (:type approval-guard-pending)))
       (funcall on-event
                '(:type tool-event :event (:type approval)))
       (funcall on-event
                '(:type tool-event :event (:type tool-error)))
       (funcall on-event
                '(:type model-usage
                  :usage (:input-tokens 11 :output-tokens 4 :total-tokens 15)))
       (funcall on-event
                '(:type agent-end :status completed :content "done"
                  :steps 1 :tool-calls nil :tool-results nil)))
     (should (= 1 (alist-get 'toolErrorCount metadata)))
     (should (= 2 (alist-get 'approvalCount metadata)))
     (should (= 15 (plist-get (alist-get 'tokenUsage metadata)
                              :total-tokens))))))

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
            :role "baseline"))
          (directory (plist-get campaign :directory))
          (descriptor (plist-get campaign :descriptor)))
     (should (file-exists-p (expand-file-name "campaign.json" directory)))
     (should (= 150 (alist-get 'expectedResultCount descriptor)))
     (should (= 64 (length (alist-get 'configurationDigest descriptor))))
     (should (equal "baseline-revision"
                    (alist-get 'implementationRevision descriptor)))
     (should-error (chat-coding-eval--complete-campaign campaign nil))
     (should-not (file-exists-p
                  (expand-file-name "completion.json" directory)))
     (should-error
      (chat-coding-eval-prepare-campaign
       "baseline-001" 'provider-a "model-a" 5
       chat-coding-eval-test-manifest
       :implementation-revision "baseline-revision"
       :role "baseline")))))

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
            :implementation-revision "resume-revision"))
          (directory (plist-get campaign :directory)))
     (should-error
      (chat-coding-eval--load-open-campaign
       directory manifest "different-revision"))
     (let ((chat-coding-eval-approval-mode 'manual))
       (should-error
        (chat-coding-eval--load-open-campaign
         directory manifest "resume-revision")))
     (write-region "\n" nil manifest t 'silent)
     (should-error
      (chat-coding-eval--load-open-campaign
       directory manifest "resume-revision")))))

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
                  (lambda (_task _workspace _done) #'ignore))))
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
        (funcall done 'completed "fixed" nil))
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

(ert-deftest chat-coding-eval-records-crash-cancel-and-timeout ()
  "Every executor terminal path produces evidence and removes its workspace."
  (chat-coding-eval-test-with-runtime
   (let* ((fixture (expand-file-name "coding-eval/python"
                                     chat-test-fixtures-dir))
          (judges '(((type . "no-change") (name . "unchanged"))))
          (task (chat-coding-eval-test--task fixture judges))
          crash-result cancel-result timeout-result cancel-called)
     (chat-coding-eval-run
      task (lambda (&rest _args) (error "executor crashed"))
      :on-complete (lambda (value _state) (setq crash-result value)))
     (should (eq 'error (chat-eval-result-status crash-result)))
     (let ((state
            (chat-coding-eval-run
             task
             (lambda (_task _workspace _done)
               (lambda () (setq cancel-called t)))
             :on-complete (lambda (value _state) (setq cancel-result value)))))
       (should (chat-coding-eval-cancel state)))
     (should cancel-called)
     (should (eq 'cancelled (chat-eval-result-status cancel-result)))
     (setf (chat-coding-eval-task-timeout-seconds task) 0.03)
     (chat-coding-eval-run
      task (lambda (_task _workspace _done) nil)
      :on-complete (lambda (value _state) (setq timeout-result value)))
     (should (chat-coding-eval-test--wait (lambda () timeout-result)))
     (should (eq 'timed-out (chat-eval-result-status timeout-result)))
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
              (funcall done 'completed "done" nil))
            :on-complete (lambda (value _state) (setq result value))))
     (setq process (chat-coding-eval-run-state-process state))
     (should (chat-coding-eval-test--wait (lambda () result)))
     (should (eq 'timed-out (chat-eval-result-status result)))
     (should-not (process-live-p process))
     (should-not (file-exists-p
                  (chat-coding-eval-run-state-workspace state))))))

(provide 'test-chat-coding-eval)
;;; test-chat-coding-eval.el ends here
