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

(ert-deftest chat-coding-acceptance-never-passes-a-missing-live-comparison ()
  "Absent M9 or M17 trials produce a blocked gate, never an invented score."
  (let ((gates (chat-coding-acceptance-live-gates nil nil)))
    (should (= 2 (length gates)))
    (should (seq-every-p
             (lambda (gate)
               (eq 'blocked (chat-coding-acceptance-gate-status gate)))
             gates))
    (should (eq 'blocked
                (chat-coding-acceptance-overall-status gates)))))

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
                            "executor-status" nil 'completed 'failed))
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
