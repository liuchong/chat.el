#!/usr/bin/env emacs -Q -batch -l
;;; run-runtime-reliability.el --- Measure Goal and Plan reliability -*- lexical-binding: t; -*-

;;; Commentary:

;; Run from the repository root:
;;   emacs -Q -batch -l tests/performance/run-runtime-reliability.el
;;
;; Set CHAT_RELIABILITY_OUTPUT to persist the JSON record.  The runner executes
;; the directed scenarios before deriving any acceptance value; missing or
;; failing scenarios therefore cannot turn into default passing measurements.

;;; Code:

(require 'ert)
(require 'json)
(require 'seq)
(require 'subr-x)

(defconst chat-runtime-reliability--root
  (file-name-as-directory
   (file-truename
    (expand-file-name "../.." (file-name-directory load-file-name)))))
(defconst chat-runtime-reliability--state
  (make-temp-file "chat-runtime-reliability-" t))

(setq default-directory chat-runtime-reliability--root
      chat-session-directory
      (expand-file-name "sessions/" chat-runtime-reliability--state)
      chat-tool-forge-directory
      (expand-file-name "tools/" chat-runtime-reliability--state)
      chat-edit-backup-directory
      (expand-file-name "backups/" chat-runtime-reliability--state)
      chat-code-intel-index-directory
      (expand-file-name "index/" chat-runtime-reliability--state)
      chat-log-file (expand-file-name "chat.log" chat-runtime-reliability--state)
      chat-wiki-root (expand-file-name "wiki/" chat-runtime-reliability--state))
(setenv "HOME" chat-runtime-reliability--state)
(dolist (directory (list chat-session-directory chat-tool-forge-directory
                         chat-edit-backup-directory
                         chat-code-intel-index-directory))
  (make-directory directory t))
(add-to-list 'load-path (expand-file-name "tests/unit" default-directory))
(load (expand-file-name "tests/test-paths.el" default-directory) nil t)
(load (expand-file-name "tests/unit/test-helper.el" default-directory) nil t)
(load (expand-file-name "chat.el" default-directory) nil t)
(dolist (file '("test-chat-goal.el" "test-chat-plan-mode.el"
                "test-chat-capability-packs.el"))
  (load (expand-file-name file (expand-file-name "tests/unit" default-directory))
        nil t))

(defconst chat-runtime-reliability--groups
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
     chat-plan-mode-persists-read-only-state-across-reload))
  "Directed scenarios that produce each non-token reliability value.")

(defun chat-runtime-reliability--run-test (name)
  "Run ERT test NAME and return a bounded result alist."
  (let* ((stats (ert-run-tests-batch name))
         (passed (= (ert-stats-completed-expected stats) 1)))
    `((test . ,(symbol-name name))
      (passed . ,(if passed t :json-false)))))

(defun chat-runtime-reliability--rate (results)
  "Return the passing ratio in RESULTS."
  (let ((passed (seq-count (lambda (result) (eq t (alist-get 'passed result)))
                           results)))
    (/ (float passed) (max 1 (length results)))))

(defun chat-runtime-reliability--failure-count (results)
  "Return the number of failed RESULTS."
  (seq-count (lambda (result) (not (eq t (alist-get 'passed result))))
             results))

(defun chat-runtime-reliability--median (values)
  "Return the numeric median of VALUES."
  (let* ((sorted (sort (copy-sequence values) #'<))
         (count (length sorted))
         (middle (/ count 2)))
    (if (cl-oddp count)
        (nth middle sorted)
      (/ (+ (nth (1- middle) sorted) (nth middle sorted)) 2.0))))

(defun chat-runtime-reliability--projection-samples ()
  "Measure Goal projection share across 20 growing request contexts."
  (chat-test-with-temp-dir
   (let* ((session (chat-goal-test--session))
          (_goal (chat-goal-test--create session))
          (fragment (chat-goal-context-fragment session))
          (goal-tokens
           (chat-context-count-tokens
            (chat-context-fragment-payload fragment)))
          (system-tokens
           (chat-context-count-tokens
            (chat-tool-caller-build-system-prompt
             (chat-code--compose-system-prompt))))
          (schema-tokens
           (chat-context-count-tokens
            (json-encode (chat-tool-caller-provider-tools))))
          samples)
     (dotimes (index 20)
       (chat-session-add-message
        session
        (make-chat-message
         :id (format "reliability-user-%d" index) :role :user
         :content (format "turn %d %s" index (make-string 240 ?u))))
       (chat-session-add-message
        session
        (make-chat-message
         :id (format "reliability-assistant-%d" index) :role :assistant
         :content (format "result %d %s" index (make-string 240 ?a))))
       (let* ((message-tokens
               (chat-context-total-tokens (chat-session-messages session)))
              (input-tokens
               (+ system-tokens schema-tokens goal-tokens message-tokens))
              (ratio (/ (float goal-tokens) input-tokens)))
         (push `((turn . ,(1+ index))
                 (goalTokens . ,goal-tokens)
                 (inputTokens . ,input-tokens)
                 (ratio . ,ratio))
               samples)))
     (nreverse samples))))

(defun chat-runtime-reliability--revision ()
  "Return the exact measured Git revision."
  (string-trim
   (with-temp-buffer
     (unless (zerop (process-file "git" nil t nil "rev-parse" "HEAD"))
       (error "Cannot resolve implementation revision"))
     (buffer-string))))

(defun chat-runtime-reliability--tree-clean-p ()
  "Return non-nil when the measured Git worktree has no local changes."
  (string-empty-p
   (with-temp-buffer
     (unless (zerop (process-file "git" nil t nil "status" "--porcelain"))
       (error "Cannot inspect implementation worktree"))
     (string-trim (buffer-string)))))

(defun chat-runtime-reliability--gate-record (gate)
  "Return the bounded JSON representation of acceptance GATE."
  `((name . ,(chat-coding-acceptance-gate-name gate))
    (status . ,(symbol-name (chat-coding-acceptance-gate-status gate)))
    (expected . ,(chat-coding-acceptance-gate-expected gate))
    (actual . ,(chat-coding-acceptance-gate-actual gate))))

(unwind-protect
    (let (facts evidence all-passed)
      (setq all-passed t)
      (dolist (group chat-runtime-reliability--groups)
        (let* ((field (car group))
               (results (mapcar #'chat-runtime-reliability--run-test
                                (cdr group)))
               (count-field (string-suffix-p "Count" (symbol-name field)))
               (value (if count-field
                          (chat-runtime-reliability--failure-count results)
                        (chat-runtime-reliability--rate results))))
          (unless (cl-every (lambda (result) (eq t (alist-get 'passed result)))
                            results)
            (setq all-passed nil))
          (push (cons field value) facts)
          (push (cons field (vconcat results)) evidence)))
      (let* ((projection-results
              (list (chat-runtime-reliability--run-test
                     'chat-goal-projection-is-protected-bounded-and-state-aware)))
             (samples (chat-runtime-reliability--projection-samples))
             (median
              (chat-runtime-reliability--median
               (mapcar (lambda (sample) (alist-get 'ratio sample)) samples))))
        (unless (eq t (alist-get 'passed (car projection-results)))
          (setq all-passed nil))
        (push (cons 'goalProjectionMedianRatio median) facts)
        (push (cons 'goalProjectionMedianRatio
                    `((tests . ,(vconcat projection-results))
                      (samples . ,(vconcat samples))))
              evidence))
      (let* ((runtime-reliability (nreverse facts))
             (tree-clean (chat-runtime-reliability--tree-clean-p))
             (gates
              (chat-coding-acceptance-reliability-gates
               `((runtimeReliability . ,runtime-reliability))))
             (gates-pass
              (cl-every
               (lambda (gate)
                 (eq 'passed (chat-coding-acceptance-gate-status gate)))
               gates))
             (allow-dirty
              (equal "1" (getenv "CHAT_RELIABILITY_ALLOW_DIRTY")))
             (record
              `((schemaVersion . 1)
                (implementationRevision . ,(chat-runtime-reliability--revision))
                (implementationTreeClean . ,(if tree-clean t :json-false))
                (measuredAt . ,(format-time-string "%FT%T%z"))
                (runtimeReliability . ,runtime-reliability)
                (acceptanceGates . ,(vconcat
                                     (mapcar
                                      #'chat-runtime-reliability--gate-record
                                      gates)))
                (evidence . ,(nreverse evidence))))
             (json-encoding-pretty-print t)
             (encoded (json-encode record))
             (output (getenv "CHAT_RELIABILITY_OUTPUT")))
        (unless (and gates-pass (or tree-clean allow-dirty))
          (setq all-passed nil))
        (when output
          (make-directory (file-name-directory (expand-file-name output)) t)
          (with-temp-file output
            (insert encoded "\n")))
        (princ encoded)
        (princ "\n")
        (unless all-passed
          (kill-emacs 1))))
  (when (file-directory-p chat-runtime-reliability--state)
    (delete-directory chat-runtime-reliability--state t)))

;;; run-runtime-reliability.el ends here
