;;; test-chat-coding-acceptance.el --- Final acceptance tests -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'test-helper)
(require 'chat-coding-acceptance)

(defun chat-coding-acceptance-test--result
    (status checks &optional executor tags task-id)
  "Return a coding result with STATUS, CHECKS, EXECUTOR, TAGS, and TASK-ID."
  (let ((chat-eval-auto-save nil))
    (chat-eval-record-result
     :scenario-id "coding/demo" :scenario-revision 1
     :category "coding/test" :fixture-id "fixture"
     :fixture-digest "digest" :status status :checks checks
     :metadata `((taskId . ,(or task-id "demo")) (taskTags . ,tags)
                 (fixtureIndexedFileCount .
                                          ,(if (member "large-repo" tags)
                                               10000
                                             1))
                 (outOfScopeFiles . nil)
                 (executor . ,executor)))))

(ert-deftest chat-coding-acceptance-classifies-failures-with-a-closed-taxonomy ()
  "Failure summaries distinguish tool, verification, and policy causes."
  (let* ((tool
          (chat-coding-acceptance-test--result
           'failed (list (chat-eval-check "judge" nil t nil))
           '((toolErrorCount . 1))))
         (verification
          (chat-coding-acceptance-test--result
           'failed
           (list (chat-eval-check "executor-status" t 'completed 'completed)
                 (chat-eval-check "test-suite" nil 0 1))))
         (blocked
          (chat-coding-acceptance-test--result
           'blocked (list (chat-eval-check "permission" nil t nil)))))
    (should (eq 'tool-error
                (chat-coding-acceptance-classify-failure tool)))
    (should (eq 'verification-error
                (chat-coding-acceptance-classify-failure verification)))
    (should (eq 'permission-block
                (chat-coding-acceptance-classify-failure blocked)))
    (should (= 6 (length (chat-coding-acceptance-failure-summary
                          (list tool verification blocked)))))))

(ert-deftest chat-coding-acceptance-does-not-hide-terminal-errors-as-infrastructure ()
  "Generic executor failures and cancellations remain valid capability trials."
  (let ((errored
         (chat-coding-acceptance-test--result
          'error
          (list (chat-eval-check "executor-status" nil 'completed 'error))))
        (cancelled
         (chat-coding-acceptance-test--result
          'cancelled
          (list (chat-eval-check "executor-status" nil 'completed
                                 'cancelled))
          '((approvalCount . 3)))))
    (should (eq 'model-ability
                (chat-coding-acceptance-classify-failure errored)))
    (should (eq 'model-ability
                (chat-coding-acceptance-classify-failure cancelled)))
    (should (= 2 (length (chat-coding-acceptance--valid-results
                          (list errored cancelled)))))))

(ert-deftest chat-coding-acceptance-reads-json-round-tripped-token-plists ()
  "Token usage remains measurable after a plist is serialized as a JSON array."
  (let ((result
         (chat-coding-acceptance-test--result
          'passed (list (chat-eval-check "judge" t t t))
          '((tokenUsage . [":input-tokens" 4321
                           ":output-tokens" 123])))))
    (should (= 4321 (chat-coding-acceptance--input-tokens result)))))

(ert-deftest chat-coding-acceptance-normalizes-redundant-snapshot-model ()
  "Adding the outer model to a capability snapshot does not break identity."
  (let* ((check (chat-eval-check "judge" t t t))
         (baseline
          (chat-coding-acceptance-test--result
           'passed (list check)
           '((provider . "provider") (model . "model")
             (modelCapabilitySnapshot . ((tools . t))))))
         (current
          (chat-coding-acceptance-test--result
           'passed (list check)
           '((provider . "provider") (model . "model")
             (modelCapabilitySnapshot . ((model . "model") (tools . t)))))))
    (should (chat-coding-acceptance--compatible-identities-p
             (list baseline) (list current)))))

(ert-deftest chat-coding-acceptance-never-passes-a-missing-live-comparison ()
  "Absent M9 or M19 trials produce a blocked gate, never an invented score."
  (let ((gates (chat-coding-acceptance-live-gates nil nil)))
    (should (= 2 (length gates)))
    (should (seq-every-p
             (lambda (gate)
               (eq 'blocked (chat-coding-acceptance-gate-status gate)))
             gates))
    (should (eq 'blocked
                (chat-coding-acceptance-overall-status gates)))))

(defun chat-coding-acceptance-test--reliability-facts ()
  "Return a complete passing runtime-reliability evidence object."
  (copy-tree
   '((runtimeReliability .
                         ((goalContinuityRate . 1.0)
                          (goalCompletionEvidenceRate . 1.0)
                          (goalInvalidTransitionCount . 0)
                          (goalScopeLeakCount . 0)
                          (goalProjectionMedianRatio . 0.03)
                          (planUnauthorizedMutationCount . 0)
                          (planNonUserApprovalCount . 0)
                          (planTransitionConsistencyRate . 1.0)
                          (planReadyImplicitExecutionCount . 0))))))

(ert-deftest chat-coding-acceptance-reliability-evidence-is-required ()
  "Missing Goal and Plan Mode measurements block every reliability gate."
  (let ((gates (chat-coding-acceptance-reliability-gates nil)))
    (should (= 9 (length gates)))
    (should (seq-every-p
             (lambda (gate)
               (eq 'blocked (chat-coding-acceptance-gate-status gate)))
             gates))))

(ert-deftest chat-coding-acceptance-reliability-thresholds-pass-exactly ()
  "Complete measured evidence passes every exact Goal and Plan Mode threshold."
  (let ((gates
         (chat-coding-acceptance-reliability-gates
          (chat-coding-acceptance-test--reliability-facts))))
    (should (= 9 (length gates)))
    (should (seq-every-p
             (lambda (gate)
               (eq 'passed (chat-coding-acceptance-gate-status gate)))
             gates))))

(ert-deftest chat-coding-acceptance-reliability-regressions-fail ()
  "Measured safety regressions fail rather than becoming missing evidence."
  (let* ((metadata (chat-coding-acceptance-test--reliability-facts))
         (facts (alist-get 'runtimeReliability metadata)))
    (setf (alist-get 'goalInvalidTransitionCount facts) 1
          (alist-get 'goalProjectionMedianRatio facts) 0.031
          (alist-get 'planNonUserApprovalCount facts) 1)
    (let ((failed
           (seq-filter
            (lambda (gate)
              (eq 'failed (chat-coding-acceptance-gate-status gate)))
            (chat-coding-acceptance-reliability-gates metadata))))
      (should (= 3 (length failed))))))

(ert-deftest chat-coding-acceptance-record-is-immutable-and-strict ()
  "A blocked gate yields an immutable blocked Eval result."
  (chat-test-with-temp-dir
   (let* ((chat-eval-directory (expand-file-name "eval/" temp-dir))
          (chat-eval-auto-save t)
          (gate (chat-coding-acceptance-gate-create
                 :name "live" :status 'blocked
                 :expected "evidence" :actual "missing"))
          (result (chat-coding-acceptance-record (list gate))))
     (should (eq 'blocked (chat-eval-result-status result)))
     (should (equal "acceptance/m19"
                    (chat-eval-result-scenario-id result)))
     (should (file-exists-p
              (expand-file-name
               (concat (chat-eval-result-id result) ".json")
               chat-eval-directory)))
     (should-error (chat-eval-save-result result)))))

(ert-deftest chat-coding-acceptance-large-repo-gate-measures-token-reduction ()
  "Tagged successful trials can unblock and pass the large-repo token gate."
  (let* ((check (chat-eval-check "judge" t t t))
         (baseline
          (chat-coding-acceptance-test--result
           'passed (list check)
           '((tokenUsage . ((input_tokens . 1000)))) '("large-repo")))
         (current
          (chat-coding-acceptance-test--result
           'passed (list check)
           '((tokenUsage . ((input_tokens . 800)))) '("large-repo")))
         (gate
          (chat-coding-acceptance--large-repo-token-gate
           (list baseline) (list current))))
    (should (eq 'passed (chat-coding-acceptance-gate-status gate)))))

(ert-deftest chat-coding-acceptance-large-repo-gate-rejects-small-fixtures ()
  "A large-repo label cannot substitute for measured indexed fixture size."
  (let* ((check (chat-eval-check "judge" t t t))
         (baseline
          (chat-coding-acceptance-test--result
           'passed (list check)
           '((tokenUsage . ((input_tokens . 1000)))) '("large-repo")))
         (current
          (chat-coding-acceptance-test--result
           'passed (list check)
           '((tokenUsage . ((input_tokens . 800)))) '("large-repo"))))
    (setf (alist-get 'fixtureIndexedFileCount
                     (chat-eval-result-metadata current))
          9999)
    (let ((gate
           (chat-coding-acceptance--large-repo-token-gate
            (list baseline) (list current))))
      (should (eq 'failed (chat-coding-acceptance-gate-status gate))))))

(ert-deftest chat-coding-acceptance-rejects-mixed-trial-identities ()
  "Every repeat in a task group must share one comparison identity."
  (let* ((check (chat-eval-check "judge" t t t))
         (baseline
          (chat-coding-acceptance-test--result
           'passed (list check) '((model . fixed))))
         (current-a
          (chat-coding-acceptance-test--result
           'passed (list check) '((model . fixed))))
         (current-b
          (chat-coding-acceptance-test--result
           'passed (list check) '((model . changed)))))
    (should-not
     (chat-coding-acceptance--compatible-identities-p
      (list baseline) (list current-a current-b)))))

(ert-deftest chat-coding-acceptance-rejects-mixed-runtime-profiles ()
  "Provider, model and runtime profile are part of comparison identity."
  (let* ((check (chat-eval-check "judge" t t t))
         (baseline
          (chat-coding-acceptance-test--result
           'passed (list check)
           '((provider . fixed) (model . model-v1)
             (profile . "code") (transport . "stream")
             (approvalMode . "guarded"))))
         (current
          (chat-coding-acceptance-test--result
           'passed (list check)
           '((provider . fixed) (model . model-v1)
             (profile . "review") (transport . "stream")
             (approvalMode . "guarded")))))
    (should-not
     (chat-coding-acceptance--compatible-identities-p
      (list baseline) (list current)))))

(ert-deftest chat-coding-acceptance-requires-isolated-versioned-campaigns ()
  "Live comparison rejects mixed, reused, or same-revision campaigns."
  (let* ((check (chat-eval-check "judge" t t t))
         (baseline
          (chat-coding-acceptance-test--result
           'passed (list check) '((model . fixed))))
         (current
          (chat-coding-acceptance-test--result
           'passed (list check) '((model . fixed))))
         (baseline-metadata (chat-eval-result-metadata baseline))
         (current-metadata (chat-eval-result-metadata current)))
    (setq baseline-metadata
          (append baseline-metadata
                  '((campaignId . "baseline-001")
                    (campaignRole . "baseline")
                    (campaignConfigurationDigest . "config-a")
                    (campaignManifestDigest . "manifest")
                    (implementationRevision . "revision-a"))))
    (setq current-metadata
          (append current-metadata
                  '((campaignId . "current-001")
                    (campaignRole . "current")
                    (campaignConfigurationDigest . "config-b")
                    (campaignManifestDigest . "manifest")
                    (implementationRevision . "revision-b"))))
    (setf (chat-eval-result-metadata baseline) baseline-metadata
          (chat-eval-result-metadata current) current-metadata)
    (should
     (eq 'passed
         (chat-coding-acceptance-gate-status
          (chat-coding-acceptance--campaign-gate
           (list baseline) (list current)))))
    (setf (alist-get 'implementationRevision current-metadata) "revision-a")
    (should
     (eq 'failed
         (chat-coding-acceptance-gate-status
          (chat-coding-acceptance--campaign-gate
           (list baseline) (list current)))))))

(ert-deftest chat-coding-acceptance-requires-terminal-campaign-record ()
  "A partial or mismatched campaign directory cannot satisfy final acceptance."
  (chat-test-with-temp-dir
   (let* ((directory (expand-file-name "baseline/" temp-dir))
          (metadata
           '((campaignId . "baseline-001")
             (campaignRole . "baseline")
             (campaignConfigurationDigest . "config")
             (campaignManifestDigest . "manifest")
             (implementationRevision . "revision-a")))
          (results
           (cl-loop for task below 30 append
                    (cl-loop for repetition from 1 to 5 collect
                             (chat-eval-result-create-record
                              :metadata
                              (append
                               `((taskId . ,(format "task-%02d" task))
                                 (repetition . ,repetition))
                               (copy-tree metadata)))))))
     (make-directory directory t)
     (with-temp-file (expand-file-name "campaign.json" directory)
       (insert
        (json-encode
         '((schemaVersion . 1) (campaignId . "baseline-001")
           (role . "baseline") (configurationDigest . "config")
           (manifestDigest . "manifest")
           (implementationRevision . "revision-a")
           (taskCount . 30) (repetitions . 5)
           (expectedResultCount . 150)))))
     (should
      (eq 'failed
          (chat-coding-acceptance-gate-status
           (chat-coding-acceptance--campaign-directory-gate
            directory results "baseline"))))
     (with-temp-file (expand-file-name "completion.json" directory)
       (insert
        (json-encode
         '((schemaVersion . 1) (campaignId . "baseline-001")
           (configurationDigest . "config")
           (expectedResultCount . 150) (resultCount . 150)
           (complete . t)))))
     (should
      (eq 'passed
          (chat-coding-acceptance-gate-status
           (chat-coding-acceptance--campaign-directory-gate
            directory results "baseline"))))
     (setf (alist-get 'repetition
                      (chat-eval-result-metadata (car results)))
           2)
     (should
      (eq 'failed
          (chat-coding-acceptance-gate-status
           (chat-coding-acceptance--campaign-directory-gate
            directory results "baseline"))))
     (setf (alist-get 'repetition
                      (chat-eval-result-metadata (car results)))
           1)
     (setf (alist-get 'campaignId
                      (chat-eval-result-metadata (car results)))
           "mismatch")
     (should
      (eq 'failed
          (chat-coding-acceptance-gate-status
           (chat-coding-acceptance--campaign-directory-gate
            directory results "baseline")))))))

(ert-deftest chat-coding-acceptance-sample-gate-requires-valid-trials ()
  "Infrastructure-invalid trials do not satisfy the exact 30-by-5 sample."
  (let (baseline current)
    (dotimes (task 30)
      (dotimes (repeat 5)
        (let* ((task-id (format "task-%02d" task))
               (judge (chat-eval-check "judge" t t t))
               (executor '((model . fixed)
                           (tokenUsage . ((input_tokens . 100)))))
               (invalid (and (= task 0) (= repeat 0))))
          (push (chat-coding-acceptance-test--result
                 'passed (list judge) executor nil task-id)
                baseline)
          (push (chat-coding-acceptance-test--result
                 (if invalid 'failed 'passed)
                 (if invalid
                     (list (chat-eval-check
                            "fixture-setup" nil 'completed 'failed))
                   (list judge))
                 executor nil task-id)
                current))))
    (let* ((gates (chat-coding-acceptance-live-gates baseline current))
           (sample
            (seq-find
             (lambda (gate)
               (equal "live-eval-sample"
                      (chat-coding-acceptance-gate-name gate)))
             gates)))
      (should (eq 'failed (chat-coding-acceptance-gate-status sample)))
      (should (equal "raw=150/150 valid=150/149"
                     (chat-coding-acceptance-gate-actual sample))))))

(ert-deftest chat-coding-acceptance-token-coverage-includes-the-baseline ()
  "Sparse baseline usage blocks token comparison even when current is complete."
  (let* ((judge (chat-eval-check "judge" t t t))
         (baseline
          (chat-coding-acceptance-test--result
           'passed (list judge) '((model . fixed))))
         (current
          (chat-coding-acceptance-test--result
           'passed (list judge)
           '((model . fixed) (tokenUsage . ((input_tokens . 100))))))
         (coverage
          (seq-find
           (lambda (gate)
             (equal "live-eval-token-coverage"
                    (chat-coding-acceptance-gate-name gate)))
           (chat-coding-acceptance-live-gates
            (list baseline) (list current)))))
    (should (eq 'blocked
                (chat-coding-acceptance-gate-status coverage)))
    (should (equal '((baseline . 1.0) (current . 0.0))
                   (chat-coding-acceptance-gate-actual coverage)))))

(ert-deftest chat-coding-acceptance-cancel-discards-fixture-and-timer ()
  "Cancelling an owned benchmark removes its timer, map, and fixture."
  (let* ((chat-repo-map--cache (make-hash-table :test 'equal))
         (before (directory-files temporary-file-directory nil
                                  "^chat-repo-benchmark-"))
         result
         (cancel
          (chat-coding-acceptance-benchmark
           :file-count 20 :repetitions 20
           :on-complete (lambda (value) (setq result value)))))
    (funcall cancel)
    (accept-process-output nil 0.02)
    (should-not result)
    (should (= 0 (hash-table-count chat-repo-map--cache)))
    (should (equal before
                   (directory-files temporary-file-directory nil
                                    "^chat-repo-benchmark-")))))

(ert-deftest chat-coding-acceptance-benchmark-covers-every-stage-and-cleans-up ()
  "A small fixture exercises index, increment, query, context, and memory."
  (let* ((chat-repo-map--cache (make-hash-table :test 'equal))
         (before (directory-files temporary-file-directory nil
                                  "^chat-repo-benchmark-"))
         (result (chat-coding-acceptance-benchmark-sync
                  :file-count 20 :repetitions 20 :timeout 30))
         (after (directory-files temporary-file-directory nil
                                 "^chat-repo-benchmark-")))
    (should (= 20 (plist-get result :file-count)))
    (should (= 20 (plist-get (plist-get result :cold-result) :files)))
    (should (= 1 (plist-get (plist-get result :incremental-result) :changed)))
    (should (numberp (plist-get result :warm-query-p95-ms)))
    (should (numberp (plist-get result :context-build-p95-ms)))
    (should (numberp (plist-get result :heap-delta-bytes)))
    (should (equal before after))))

(provide 'test-chat-coding-acceptance)
;;; test-chat-coding-acceptance.el ends here
