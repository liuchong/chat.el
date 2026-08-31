;;; test-chat-coding-acceptance.el --- Final acceptance tests -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'test-helper)
(require 'chat-coding-acceptance)

(ert-deftest chat-coding-acceptance-quality-scenarios-use-current-shelf-contract ()
  "The quality record measures the current input work-shelf stability test."
  (let ((tests (apply #'append
                      (mapcar #'cddr
                              chat-coding-acceptance-quality-scenarios))))
    (should (memq 'chat-work-shelf-thousand-updates-preserve-input-and-window
                  tests))
    (should-not
     (memq 'chat-work-plan-ui-thousand-updates-preserve-input-and-window
           tests))))

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

(ert-deftest chat-coding-acceptance-reads-json-round-tripped-first-request-usage ()
  "First-request usage remains measurable after JSON round trip."
  (let ((result
         (chat-coding-acceptance-test--result
          'passed (list (chat-eval-check "judge" t t t))
          '((firstRequestTokenUsage . [":input-tokens" 4321
                                       ":output-tokens" 123])))))
    (should (= 4321
               (chat-coding-acceptance--first-request-input-tokens result)))))

(ert-deftest chat-coding-acceptance-normalizes-capability-schema-evolution ()
  "Serializer and implementation-only capability fields do not break identity."
  (let* ((check (chat-eval-check "judge" t t t))
         (baseline
          (chat-coding-acceptance-test--result
           'passed (list check)
           '((provider . "provider") (model . "model")
             (modelCapabilitySnapshot . ((schemaVersion . 1)
                                         (tools . t)
                                         (reasoning . t))))))
         (current
          (chat-coding-acceptance-test--result
           'passed (list check)
           '((provider . "provider") (model . "model")
             (modelCapabilitySnapshot . ((schemaVersion . 2)
                                         (provider . "provider")
                                         (model . "model")
                                         (tools . t)
                                         (reasoning . t)
                                         (reasoningReplay . required)))))))
    (should (chat-coding-acceptance--compatible-identities-p
             (list baseline) (list current)))))

(ert-deftest chat-coding-acceptance-rejects-common-capability-drift ()
  "A real difference in the stable capability identity remains incomparable."
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
             (modelCapabilitySnapshot . ((tools . :json-false)))))))
    (should-not (chat-coding-acceptance--compatible-identities-p
                 (list baseline) (list current)))))

(ert-deftest chat-coding-acceptance-never-passes-a-missing-live-comparison ()
  "Absent M9 or M19 trials produce a blocked gate, never an invented score."
  (let ((gates (chat-coding-acceptance-live-gates nil nil nil nil)))
    (should (= 3 (length gates)))
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

(defun chat-coding-acceptance-test--reliability-record (&optional revision)
  "Return one complete clean reliability record for REVISION."
  (let* ((metadata (chat-coding-acceptance-test--reliability-facts))
         (facts (alist-get 'runtimeReliability metadata))
         (groups
          '((goalContinuityRate
             chat-goal-plan-notes-survive-two-compactions-and-restart)
            (goalCompletionEvidenceRate
             chat-goal-progress-requires-known-scoped-evidence
             chat-goal-completion-is-deterministic-and-evidence-backed)
            (goalInvalidTransitionCount
             chat-goal-refuses-incomplete-contracts
             chat-goal-pause-block-resume-and-stale-revision)
            (goalScopeLeakCount
             chat-goal-project-scope-fails-closed-without-content-leakage)
            (planUnauthorizedMutationCount
             chat-plan-mode-tool-boundary-allows-read-and-refuses-effects
             chat-plan-mode-allows-only-dedicated-planning-state-tools)
            (planNonUserApprovalCount
             chat-capability-agent-can-enter-but-not-approve-plan-mode
             chat-plan-mode-submit-requires-complete-plan-and-user-approval)
            (planTransitionConsistencyRate
             chat-plan-mode-persists-read-only-state-across-reload
             chat-plan-mode-submit-requires-complete-plan-and-user-approval
             chat-plan-mode-approval-refuses-a-changed-submitted-plan
             chat-plan-mode-rejection-feedback-returns-to-research
             chat-plan-mode-rejects-invalid-plan-and-stale-transitions)
            (planReadyImplicitExecutionCount
             chat-plan-mode-persists-read-only-state-across-reload)))
         (gates (chat-coding-acceptance-reliability-gates metadata))
         (evidence
          (mapcar
           (lambda (group)
             (cons
              (car group)
              (vconcat
               (mapcar
                (lambda (test)
                  `((test . ,(symbol-name test)) (passed . t)))
                (cdr group)))))
           groups))
         (samples
          (vconcat
           (cl-loop for turn from 1 to 20 collect
                    `((turn . ,turn) (goalTokens . 3) (inputTokens . 100)
                      (ratio . 0.03))))))
    (push
     `(goalProjectionMedianRatio
       . ((tests . [((test . "chat-goal-projection-is-protected-bounded-and-state-aware")
                     (passed . t))])
          (samples . ,samples)))
     evidence)
    `((schemaVersion . 1)
      (implementationRevision . ,(or revision "revision-current"))
      (implementationTreeClean . t)
      (measuredAt . "2026-08-29T10:10:41+0800")
      (runtimeReliability . ,facts)
      (acceptanceGates
       . ,(vconcat
           (mapcar
            (lambda (gate)
              `((name . ,(chat-coding-acceptance-gate-name gate))
                (status . "passed")
                (expected . ,(chat-coding-acceptance-gate-expected gate))
                (actual . ,(chat-coding-acceptance-gate-actual gate))))
            gates)))
      (evidence . ,evidence))))

(defun chat-coding-acceptance-test--quality-record (&optional revision)
  "Return one complete clean quality record for REVISION."
  (let* ((semantic-corpus
          (vconcat
           (mapcar
            (lambda (language)
              `((language . ,language)
                (definitionExpected . 1) (definitionHits . 1)
                (referenceExpected . 1) (referenceReturned . 1)
                (referenceTrue . 1)
                (topFiveQueries . 1) (topFiveHits . 1)))
            chat-coding-acceptance-quality-languages)))
         (review-corpus
          '((expectedCriticalHigh . ["c1" "h1" "h2" "c2" "h3" "h4" "c3"])
            (reportedFormal . ["c1" "h1" "h2" "c2" "h3" "h4" "c3"
                               "low-noise"])))
         (prompt-samples
          (vconcat
           (cl-loop for turn from 1 to 20 collect
                    `((turn . ,turn) (planTokens . 3)
                      (workNoteTokens . 1) (inputTokens . 100)
                      (ratio . 0.04)))))
         (facts
          `((semantic .
                      ,(chat-coding-acceptance--semantic-summary
                        semantic-corpus))
            (review .
                    ,(chat-coding-acceptance--review-summary review-corpus))
            (planWorkNotePromptMedianRatio . 0.04)))
         (evidence
          `((semanticCorpus . ,semantic-corpus)
            (reviewCorpus . ,review-corpus)
            (planWorkNotePromptMedianRatio
             . ((samples . ,prompt-samples)))))
         (scenario-evidence
          (mapcar
           (lambda (group)
             (cons
              (car group)
              (vconcat
               (mapcar
                (lambda (test)
                  `((test . ,(symbol-name test)) (passed . t)))
                (cddr group)))))
           chat-coding-acceptance-quality-scenarios))
         (metadata
          `((qualityReliability . ,facts)
            (evidence . ,(append evidence scenario-evidence))))
         (gates (chat-coding-acceptance-quality-gates metadata)))
    `((schemaVersion . 1)
      (implementationRevision . ,(or revision "revision-current"))
      (implementationTreeClean . t)
      (measuredAt . "2026-08-29T12:00:00+0800")
      (qualityReliability . ,facts)
      (acceptanceGates
       . ,(vconcat
           (mapcar
            (lambda (gate)
              `((name . ,(chat-coding-acceptance-gate-name gate))
                (status . "passed")
                (expected . ,(chat-coding-acceptance-gate-expected gate))
                (actual . ,(chat-coding-acceptance-gate-actual gate))))
            gates)))
      (evidence . ,(append evidence scenario-evidence)))))

(defun chat-coding-acceptance-test--canonical-record (&optional revision)
  "Return one complete clean canonical record for REVISION."
  (let ((names (chat-coding-acceptance--canonical-test-names)))
    (copy-tree
     `((schemaVersion . 1)
       (implementationRevision . ,(or revision "revision-current"))
       (implementationTreeClean . t)
       (measuredAt . "2026-08-29T12:30:00+0800")
       (summary . ((total . ,(length names)) (passed . ,(length names))
                   (failed . 0) (skipped . 0) (unexpected . 0)))
       (tests . ,(vconcat
                  (mapcar (lambda (name)
                            (list (cons 'test name) (cons 'passed t)))
                          names)))))))

(defun chat-coding-acceptance-test--request-footprint-record (&optional revision)
  "Return one complete clean footprint record for REVISION."
  (copy-tree
   `((schemaVersion . 1)
     (implementationRevision . ,(or revision "revision-current"))
     (implementationTreeClean . t)
     (measuredAt . "2026-08-30T11:00:00+0800")
     (metric . "message-content-plus-provider-tools-json-bytes")
     (baselineRevision . "e4e6cbcec89a8a0d5f67d15a861ace9d9b4965d3")
     (baselineCombinedBytes . 6324)
     (maxCombinedRatio . 1.1)
     (currentCombinedBytes . 6605)
     (currentRatio . 1.0444339025932954)
     (passed . t))))

(ert-deftest chat-coding-acceptance-footprint-record-is-required-and-bound ()
  "Footprint evidence must be clean, internally consistent and revision-bound."
  (let ((record (chat-coding-acceptance-test--request-footprint-record)))
    (should
     (eq 'passed
         (chat-coding-acceptance-gate-status
          (chat-coding-acceptance-request-footprint-record-gate
           record "revision-current"))))
    (should
     (eq 'blocked
         (chat-coding-acceptance-gate-status
          (chat-coding-acceptance-request-footprint-record-gate
           record "another-revision"))))
    (setf (alist-get 'currentRatio record) 0.5)
    (should
     (eq 'blocked
         (chat-coding-acceptance-gate-status
          (chat-coding-acceptance-request-footprint-record-gate
           record "revision-current"))))
    (setq record (chat-coding-acceptance-test--request-footprint-record))
    (setf (alist-get 'currentCombinedBytes record) 7000
          (alist-get 'currentRatio record) (/ 7000.0 6324)
          (alist-get 'passed record) :json-false)
    (should
     (eq 'failed
         (chat-coding-acceptance-gate-status
          (chat-coding-acceptance-request-footprint-record-gate
           record "revision-current"))))))

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

(ert-deftest chat-coding-acceptance-reliability-record-provenance-is-required ()
  "Nine hand-written values cannot substitute for the measured record."
  (let ((gate
         (chat-coding-acceptance-reliability-record-gate
          (chat-coding-acceptance-test--reliability-facts)
          "revision-current")))
    (should (eq 'blocked (chat-coding-acceptance-gate-status gate)))))

(ert-deftest chat-coding-acceptance-reliability-record-is-revision-bound ()
  "A complete clean record passes only for its measured implementation."
  (let* ((record (chat-coding-acceptance-test--reliability-record))
         (passing
          (chat-coding-acceptance-reliability-record-gate
           record "revision-current"))
         (mismatch
          (chat-coding-acceptance-reliability-record-gate
           record "another-revision")))
    (should (eq 'passed (chat-coding-acceptance-gate-status passing)))
    (should (eq 'blocked (chat-coding-acceptance-gate-status mismatch)))))

(ert-deftest chat-coding-acceptance-reliability-record-requires-clean-full-evidence ()
  "Dirty measurements and incomplete projection samples remain blocked."
  (let ((dirty (chat-coding-acceptance-test--reliability-record))
        (short (chat-coding-acceptance-test--reliability-record)))
    (setf (alist-get 'implementationTreeClean dirty) :json-false)
    (setf (alist-get 'samples
                     (alist-get 'goalProjectionMedianRatio
                                (alist-get 'evidence short)))
          [])
    (should
     (eq 'blocked
         (chat-coding-acceptance-gate-status
          (chat-coding-acceptance-reliability-record-gate
           dirty "revision-current"))))
    (should
     (eq 'blocked
         (chat-coding-acceptance-gate-status
          (chat-coding-acceptance-reliability-record-gate
           short "revision-current"))))))

(ert-deftest chat-coding-acceptance-quality-evidence-is-required ()
  "Missing non-live quality evidence blocks every quality gate."
  (let ((gates (chat-coding-acceptance-quality-gates nil)))
    (should (> (length gates) 10))
    (should (seq-every-p
             (lambda (gate)
               (eq 'blocked (chat-coding-acceptance-gate-status gate)))
             gates))))

(ert-deftest chat-coding-acceptance-quality-language-details-are-required ()
  "Missing per-language metrics block rather than report a regression."
  (let* ((record (chat-coding-acceptance-test--quality-record))
         (facts (alist-get 'qualityReliability record))
         (semantic (alist-get 'semantic facts)))
    (setf (alist-get 'byLanguage semantic) nil)
    (let ((gate
           (seq-find
            (lambda (candidate)
              (equal "semantic-language-spread"
                     (chat-coding-acceptance-gate-name candidate)))
            (chat-coding-acceptance-quality-gates record))))
      (should gate)
      (should (eq 'blocked (chat-coding-acceptance-gate-status gate))))))

(ert-deftest chat-coding-acceptance-quality-record-is-revision-bound ()
  "Complete quality evidence passes only for its measured implementation."
  (let ((record (chat-coding-acceptance-test--quality-record)))
    (should
     (eq 'passed
         (chat-coding-acceptance-gate-status
          (chat-coding-acceptance-quality-record-gate
           record "revision-current"))))
    (should
     (eq 'blocked
         (chat-coding-acceptance-gate-status
          (chat-coding-acceptance-quality-record-gate
           record "another-revision"))))))

(ert-deftest chat-coding-acceptance-quality-record-rejects-rewritten-facts ()
  "A hand-edited metric cannot disagree with its raw corpus evidence."
  (let* ((record (chat-coding-acceptance-test--quality-record))
         (facts (alist-get 'qualityReliability record))
         (semantic (alist-get 'semantic facts))
         (overall (alist-get 'overall semantic)))
    (setf (alist-get 'definitionAccuracy overall) 0.99)
    (should
     (eq 'blocked
         (chat-coding-acceptance-gate-status
          (chat-coding-acceptance-quality-record-gate
           record "revision-current"))))))

(ert-deftest chat-coding-acceptance-quality-record-requires-clean-full-evidence ()
  "Dirty measurements and incomplete directed scenarios remain blocked."
  (let ((dirty (chat-coding-acceptance-test--quality-record))
        (short (chat-coding-acceptance-test--quality-record)))
    (setf (alist-get 'implementationTreeClean dirty) :json-false)
    (setf (alist-get 'editingSafety (alist-get 'evidence short)) [])
    (dolist (record (list dirty short))
      (should
       (eq 'blocked
           (chat-coding-acceptance-gate-status
            (chat-coding-acceptance-quality-record-gate
             record "revision-current")))))))

(ert-deftest chat-coding-acceptance-canonical-record-is-required-and-bound ()
  "Canonical evidence must be complete, clean, and revision-bound."
  (let ((record (chat-coding-acceptance-test--canonical-record)))
    (should
     (eq 'passed
         (chat-coding-acceptance-gate-status
          (chat-coding-acceptance-canonical-record-gate
           record "revision-current"))))
    (should
     (eq 'blocked
         (chat-coding-acceptance-gate-status
          (chat-coding-acceptance-canonical-record-gate
           record "another-revision"))))
    (setf (alist-get 'implementationTreeClean record) :json-false)
    (should
     (eq 'blocked
         (chat-coding-acceptance-gate-status
          (chat-coding-acceptance-canonical-record-gate
           record "revision-current"))))))

(ert-deftest chat-coding-acceptance-canonical-record-rejects-partial-summary ()
  "A passing total cannot hide a missing or failed canonical test."
  (let* ((record (chat-coding-acceptance-test--canonical-record))
         (tests (append (alist-get 'tests record) nil)))
    (setf (alist-get 'tests record) (vconcat (cdr tests)))
    (should
     (eq 'blocked
         (chat-coding-acceptance-gate-status
          (chat-coding-acceptance-canonical-record-gate
           record "revision-current"))))
    (setq record (chat-coding-acceptance-test--canonical-record))
    (setf (alist-get 'passed (car (append (alist-get 'tests record) nil)))
          :json-false)
    (should
     (eq 'blocked
         (chat-coding-acceptance-gate-status
          (chat-coding-acceptance-canonical-record-gate
           record "revision-current"))))))

(ert-deftest chat-coding-acceptance-final-binds-evidence-to-current-campaign ()
  "Final aggregation binds every evidence record to current trials."
  (chat-test-with-temp-dir
   (let* ((baseline-directory (expand-file-name "baseline/" temp-dir))
          (current-directory (expand-file-name "current/" temp-dir))
          (baseline (chat-coding-acceptance-test--result 'passed nil))
          (current (chat-coding-acceptance-test--result 'passed nil))
          (record (chat-coding-acceptance-test--reliability-record))
          (quality-record (chat-coding-acceptance-test--quality-record))
          (canonical-record
           (chat-coding-acceptance-test--canonical-record))
          (footprint-record
           (chat-coding-acceptance-test--request-footprint-record)))
     (make-directory baseline-directory t)
     (make-directory current-directory t)
     (setf (alist-get 'implementationRevision
                      (chat-eval-result-metadata baseline))
           "revision-baseline"
           (alist-get 'implementationRevision
                      (chat-eval-result-metadata current))
           "revision-current")
     (cl-letf (((symbol-function 'chat-coding-acceptance-benchmark-sync)
                (lambda (&rest _) nil))
               ((symbol-function
                 'chat-coding-acceptance-performance-gates)
                (lambda (_) nil))
               ((symbol-function
                 'chat-coding-acceptance-load-result-directory)
                (lambda (directory)
                  (if (equal directory current-directory)
                      (list current)
                    (list baseline))))
               ((symbol-function
                 'chat-coding-acceptance--campaign-directory-gate)
                (lambda (&rest _)
                  (chat-coding-acceptance-gate-create
                   :name "campaign" :status 'passed)))
               ((symbol-function 'chat-coding-acceptance-live-gates)
                (lambda (&rest _) nil))
               ((symbol-function 'chat-coding-acceptance-record)
                (lambda (gates &optional _) gates)))
       (let* ((gates
               (chat-coding-acceptance-run-final
                baseline-directory current-directory nil nil
                record quality-record canonical-record footprint-record))
              (provenance
               (seq-find
                (lambda (gate)
                  (equal "runtime-reliability-record"
                         (chat-coding-acceptance-gate-name gate)))
                gates))
              (quality-provenance
               (seq-find
                (lambda (gate)
                  (equal "quality-reliability-record"
                         (chat-coding-acceptance-gate-name gate)))
                gates))
              (canonical-provenance
               (seq-find
                (lambda (gate)
                  (equal "canonical-suite-record"
                         (chat-coding-acceptance-gate-name gate)))
                gates))
              (footprint-provenance
               (seq-find
                (lambda (gate)
                  (equal "first-request-footprint-record"
                         (chat-coding-acceptance-gate-name gate)))
                gates)))
         (should provenance)
         (should (eq 'passed
                     (chat-coding-acceptance-gate-status provenance)))
         (should quality-provenance)
         (should
          (eq 'passed
              (chat-coding-acceptance-gate-status
               quality-provenance)))
         (should canonical-provenance)
         (should
          (eq 'passed
              (chat-coding-acceptance-gate-status
               canonical-provenance)))
         (should footprint-provenance)
         (should
          (eq 'passed
              (chat-coding-acceptance-gate-status
               footprint-provenance))))))))

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
           '((firstRequestTokenUsage . ((input_tokens . 1000))))
           '("large-repo")))
         (current
          (chat-coding-acceptance-test--result
           'passed (list check)
           '((firstRequestTokenUsage . ((input_tokens . 800))))
           '("large-repo")))
         (gate
          (chat-coding-acceptance--large-repo-token-gate
           (list baseline) (list current))))
    (should (eq 'passed (chat-coding-acceptance-gate-status gate)))))

(ert-deftest chat-coding-acceptance-large-repo-uses-valid-failed-baseline ()
  "Correctness failure does not erase a trustworthy performance sample."
  (let* ((baseline
          (chat-coding-acceptance-test--result
           'failed (list (chat-eval-check "judge" nil t nil))
           '((firstRequestTokenUsage . ((input_tokens . 1000))))
           '("large-repo")))
         (current
          (chat-coding-acceptance-test--result
           'passed (list (chat-eval-check "judge" t t t))
           '((firstRequestTokenUsage . ((input_tokens . 800))))
           '("large-repo")))
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
           '((firstRequestTokenUsage . ((input_tokens . 1000))))
           '("large-repo")))
         (current
          (chat-coding-acceptance-test--result
           'passed (list check)
           '((firstRequestTokenUsage . ((input_tokens . 800))))
           '("large-repo"))))
    (setf (alist-get 'fixtureIndexedFileCount
                     (chat-eval-result-metadata current))
          9999)
    (let ((gate
           (chat-coding-acceptance--large-repo-token-gate
            (list baseline) (list current))))
      (should (eq 'failed (chat-coding-acceptance-gate-status gate))))))

(ert-deftest chat-coding-acceptance-large-repo-evidence-matches-core-revisions ()
  "Dedicated token trials must preserve core task and implementation identity."
  (let* ((judge (chat-eval-check "judge" t t t))
         (executor '((provider . fixed-provider) (model . fixed-model)
                     (profile . code) (transport . openai)
                     (approvalMode . guarded)))
         (core-baseline
          (chat-coding-acceptance-test--result
           'passed (list judge) executor '("large-repo") "python-locate"))
         (core-current
          (chat-coding-acceptance-test--result
           'passed (list judge) executor '("large-repo") "python-locate"))
         performance-baseline performance-current)
    (setf (alist-get 'implementationRevision
                     (chat-eval-result-metadata core-baseline))
          "old-revision"
          (alist-get 'implementationRevision
                     (chat-eval-result-metadata core-current))
          "new-revision")
    (dotimes (_ 5)
      (let ((baseline
             (chat-coding-acceptance-test--result
              'passed (list judge) executor '("large-repo") "python-locate"))
            (current
             (chat-coding-acceptance-test--result
              'passed (list judge) executor '("large-repo") "python-locate")))
        (dolist (entry `((,baseline "large-baseline" "baseline"
                                   "baseline-config" "old-revision")
                         (,current "large-current" "current"
                                   "current-config" "new-revision")))
          (setf (chat-eval-result-metadata (car entry))
                (append
                 `((campaignId . ,(nth 1 entry))
                   (campaignRole . ,(nth 2 entry))
                   (campaignConfigurationDigest . ,(nth 3 entry))
                   (campaignManifestDigest . "large-manifest")
                   (implementationRevision . ,(nth 4 entry)))
                 (chat-eval-result-metadata (car entry)))))
        (push baseline performance-baseline)
        (push current performance-current)))
    (let ((gate
           (chat-coding-acceptance--large-repo-evidence-gate
            (list core-baseline) (list core-current)
            performance-baseline performance-current)))
      (should (eq 'passed (chat-coding-acceptance-gate-status gate)))
      (setf (alist-get 'implementationRevision
                       (chat-eval-result-metadata
                        (car performance-current)))
            "wrong-revision")
      (should
       (eq 'failed
           (chat-coding-acceptance-gate-status
            (chat-coding-acceptance--large-repo-evidence-gate
             (list core-baseline) (list core-current)
             performance-baseline performance-current)))))))

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
                           (firstRequestTokenUsage .
                                                   ((input_tokens . 100)))))
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
    (let* ((gates (chat-coding-acceptance-live-gates
                   baseline current nil nil))
           (sample
            (seq-find
             (lambda (gate)
               (equal "live-eval-sample"
                      (chat-coding-acceptance-gate-name gate)))
             gates)))
      (should (eq 'failed (chat-coding-acceptance-gate-status sample)))
      (should (equal "raw=150/150 valid=150/149"
                     (chat-coding-acceptance-gate-actual sample))))))

(ert-deftest chat-coding-acceptance-first-request-coverage-includes-baseline ()
  "Sparse baseline usage blocks token comparison even when current is complete."
  (let* ((judge (chat-eval-check "judge" t t t))
         (baseline
          (chat-coding-acceptance-test--result
           'passed (list judge) '((model . fixed))))
         (current
          (chat-coding-acceptance-test--result
           'passed (list judge)
           '((model . fixed)
             (firstRequestTokenUsage . ((input_tokens . 100))))))
         (coverage
          (seq-find
           (lambda (gate)
             (equal "live-eval-first-request-token-coverage"
                    (chat-coding-acceptance-gate-name gate)))
           (chat-coding-acceptance-live-gates
            (list baseline) (list current) nil nil))))
    (should (eq 'blocked
                (chat-coding-acceptance-gate-status coverage)))
    (should (equal '((baseline . 1.0) (current . 0.0))
                   (chat-coding-acceptance-gate-actual coverage)))))

(ert-deftest chat-coding-acceptance-token-budget-measures-first-request-only ()
  "Later agent turns cannot redefine the fixed request-overhead gate."
  (let* ((judge (chat-eval-check "judge" t t t))
         (baseline
          (chat-coding-acceptance-test--result
           'passed (list judge)
           '((firstRequestTokenUsage . ((input_tokens . 100)))
             (finalRequestTokenUsage . ((input_tokens . 100))))))
         (current
          (chat-coding-acceptance-test--result
           'passed (list judge)
           '((firstRequestTokenUsage . ((input_tokens . 105)))
             (finalRequestTokenUsage . ((input_tokens . 1000))))))
         (gate
          (seq-find
           (lambda (candidate)
             (equal "live-eval-first-request-input-token-budget"
                    (chat-coding-acceptance-gate-name candidate)))
           (chat-coding-acceptance-live-gates
            (list baseline) (list current) nil nil))))
    (should (eq 'passed (chat-coding-acceptance-gate-status gate)))
    (should (equal '((baseline . 100) (current . 105))
                   (chat-coding-acceptance-gate-actual gate)))))

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
