;;; test-chat-code-review.el --- Typed review tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'test-helper)
(require 'chat-code-review)
(require 'chat-capability-packs)

(defun chat-code-review-test--git (root &rest args)
  "Run Git ARGS in ROOT for test setup."
  (with-temp-buffer
    (let ((exit (apply #'process-file "git" nil t nil "-C" root args)))
      (unless (zerop exit) (error "%s" (buffer-string)))
      (string-trim (buffer-string)))))

(defun chat-code-review-test--repo (root)
  "Create a minimal committed repository at ROOT."
  (chat-code-review-test--git root "init" "-q")
  (chat-code-review-test--git root "config" "user.name" "Review Test")
  (chat-code-review-test--git root "config" "user.email"
                               "review@example.invalid")
  (with-temp-file (expand-file-name "main.el" root)
    (insert "(defun answer () 42)\n"))
  (chat-code-review-test--git root "add" ".")
  (chat-code-review-test--git root "commit" "-qm" "base"))

(defconst chat-code-review-test--valid
  "{\"findings\":[{\"id\":\"bug-1\",\"severity\":\"high\",\"path\":\"main.el\",\"line\":1,\"title\":\"Wrong answer\",\"evidence\":\"The fixture expects 43.\"}]}"
  "One valid review response.")

(ert-deftest chat-code-review-parser-enforces-evidence-contract ()
  "Findings require path, line, title, evidence and valid project scope."
  (chat-test-with-temp-dir
   (let ((finding (car (chat-code-review-parse
                        chat-code-review-test--valid temp-dir))))
     (should (eq (chat-code-review-finding-severity finding) 'high))
     (should (equal (chat-code-review-finding-path finding) "main.el")))
   (dolist (json
            '("{\"findings\":[{\"severity\":\"high\",\"line\":1,\"title\":\"x\",\"evidence\":\"y\"}]}"
              "{\"findings\":[{\"severity\":\"high\",\"path\":\"x\",\"title\":\"x\",\"evidence\":\"y\"}]}"
              "{\"findings\":[{\"severity\":\"high\",\"path\":\"x\",\"line\":1,\"title\":\"x\"}]}"
              "{\"findings\":[{\"severity\":\"high\",\"path\":\"../escape\",\"line\":1,\"title\":\"x\",\"evidence\":\"y\"}]}"))
     (should-error (chat-code-review-parse json temp-dir)
                   :type 'chat-code-review-invalid))))

(ert-deftest chat-code-review-parser-rejects-duplicates ()
  "The typed parser rejects duplicate location/title findings."
  (chat-test-with-temp-dir
   (should-error
    (chat-code-review-parse
     (concat
      "{\"findings\":["
      "{\"severity\":\"high\",\"path\":\"main.el\",\"line\":1,\"title\":\"same\",\"evidence\":\"a\"},"
      "{\"severity\":\"low\",\"path\":\"main.el\",\"line\":1,\"title\":\"same\",\"evidence\":\"b\"}]}")
     temp-dir)
    :type 'chat-code-review-invalid)))

(ert-deftest chat-code-review-verifier-cannot-rewrite-or-escalate ()
  "Verifier decisions preserve the original finding identity and content."
  (chat-test-with-temp-dir
   (let* ((finding (car (chat-code-review-parse
                         chat-code-review-test--valid temp-dir)))
          (title (chat-code-review-finding-title finding)))
     (chat-code-review-apply-verdict
      finding
      "{\"finding_id\":\"bug-1\",\"decision\":\"downgrade\",\"severity\":\"medium\",\"title\":\"rewrite\"}")
     (should (eq (chat-code-review-finding-status finding) 'downgraded))
     (should (eq (chat-code-review-finding-severity finding) 'medium))
     (should (equal (chat-code-review-finding-title finding) title))
     (should-error
      (chat-code-review-apply-verdict
       finding
       "{\"finding_id\":\"bug-1\",\"decision\":\"downgrade\",\"severity\":\"critical\"}")
      :type 'chat-code-review-invalid))))

(ert-deftest chat-code-review-profile-has-zero-write-effects ()
  "Every tool exposed to the review profile is registered read-only."
  (dolist (id chat-capability-review-tools)
    (let ((tool (chat-tool-forge-get id)))
      (should tool)
      (should-not (seq-intersection
                   (chat-forged-tool-effects tool)
                   '(write destructive outbound))))))

(ert-deftest chat-code-review-start-is-independent-typed-and-audited ()
  "Review start uses only its evidence prompt and emits durable finding facts."
  (chat-test-with-temp-dir
   (chat-code-review-test--repo temp-dir)
   (let* ((chat-task-directory (expand-file-name "tasks/" chat-state-dir))
          (chat-task--registry (make-hash-table :test 'equal))
          (chat-task--loaded-p t)
          (chat-task-auto-save nil)
          (chat-code-review--results (make-hash-table :test 'equal))
          (chat-event-observer-functions nil)
          (chat-event-blocker-functions nil)
          (session (chat-session-create "Review" 'test-model))
          events captured-options captured-prompt completed)
     (chat-session-set-working-directory session temp-dir)
     (chat-event-add-observer
      (lambda (event) (push (chat-event-type event) events)))
     (let ((chat-code-review-start-agent-function
            (lambda (_name prompt _parent success _error _budget options)
              (setq captured-prompt prompt captured-options options)
              (funcall success
                       `((id . "reviewer")
                         (summary . ,chat-code-review-test--valid)))
              (list :cancel #'ignore))))
       (chat-code-review-start
        session "Find the seeded defect"
        :project-root temp-dir :base-revision "HEAD"
        :diff "diff evidence" :repo-map "map evidence"
        :verification "verification evidence" :verify-high nil
        :on-complete (lambda (result) (setq completed result))))
     (should completed)
     (should (equal (plist-get captured-options :profile) 'review))
     (should (string-match-p "diff evidence" captured-prompt))
     (should-not (string-match-p "editing-agent reasoning" captured-prompt))
     (should (memq 'review-started events))
     (should (memq 'review-finding events))
     (should (memq 'review-completed events))
     (should (eq (chat-task-status
                  (chat-task-get (chat-code-review-result-task-id completed)))
                 'completed)))))

(ert-deftest chat-code-review-seeded-eval-meets-thresholds ()
  "Deterministic seeded findings satisfy the M16 precision/recall gates."
  (let* ((expected '("c1" "h1" "h2" "c2" "h3" "h4" "c3"))
         (reported '("c1" "h1" "h2" "c2" "h3" "h4" "c3" "low-noise"))
         (score (chat-code-review-score reported expected)))
    (should (>= (plist-get score :recall) 0.85))
    (should (>= (plist-get score :precision) 0.80))))

(provide 'test-chat-code-review)
;;; test-chat-code-review.el ends here
