#!/usr/bin/env emacs -Q -batch -l
;;; run-quality-reliability.el --- Measure non-live coding quality -*- lexical-binding: t; -*-

;;; Commentary:

;; Run from the repository root:
;;   emacs -Q -batch -l tests/performance/run-quality-reliability.el
;;
;; Set CHAT_QUALITY_RELIABILITY_OUTPUT to persist the JSON record.  The legacy
;; CHAT_QUALITY_OUTPUT name remains accepted.  The runner measures the semantic
;; corpus, Review corpus, prompt share, and every directed safety scenario
;; before deriving the final quality gates.

;;; Code:

(require 'ert)
(require 'json)
(require 'seq)
(require 'subr-x)

(defconst chat-quality-reliability--root
  (file-name-as-directory
   (file-truename
    (expand-file-name "../.." (file-name-directory load-file-name)))))
(defconst chat-quality-reliability--state
  (make-temp-file "chat-quality-reliability-" t))

(setq default-directory chat-quality-reliability--root
      chat-session-directory
      (expand-file-name "sessions/" chat-quality-reliability--state)
      chat-tool-forge-directory
      (expand-file-name "tools/" chat-quality-reliability--state)
      chat-edit-backup-directory
      (expand-file-name "backups/" chat-quality-reliability--state)
      chat-code-intel-index-directory
      (expand-file-name "index/" chat-quality-reliability--state)
      chat-work-context-directory
      (expand-file-name "work-context/" chat-quality-reliability--state)
      chat-log-file (expand-file-name "chat.log" chat-quality-reliability--state)
      chat-wiki-root (expand-file-name "wiki/" chat-quality-reliability--state))
(setenv "HOME" chat-quality-reliability--state)
(dolist (directory (list chat-session-directory chat-tool-forge-directory
                         chat-edit-backup-directory
                         chat-code-intel-index-directory
                         chat-work-context-directory))
  (make-directory directory t))
(add-to-list 'load-path (expand-file-name "tests/unit" default-directory))
(load (expand-file-name "tests/test-paths.el" default-directory) nil t)
(load (expand-file-name "tests/unit/test-helper.el" default-directory) nil t)
(load (expand-file-name "chat.el" default-directory) nil t)
(dolist (file '("test-chat-files.el" "test-chat-checkpoint.el"
                "test-chat-code-verify.el" "test-chat-execution-isolation.el"
                "test-chat-project.el" "test-chat-work-context.el"
                "test-chat-work-plan.el" "test-chat-work-plan-ui.el"
                "test-chat-agent.el" "test-chat-code-review.el"
                "test-chat-code-collaboration.el"
                "test-chat-code-intelligence.el" "test-chat-repo-map.el"))
  (load (expand-file-name file (expand-file-name "tests/unit" default-directory))
        nil t))

(defconst chat-quality-reliability--semantic-fixtures
  '(("python" "alpha" "a.py" 1
     "def alpha():\n    return 1\ndef caller():\n    return alpha()\n")
    ("typescript" "beta" "b.ts" 1
     "function beta() { return 1; }\nexport const caller = beta;\n")
    ("emacs-lisp" "gamma" "c.el" 1
     "(defun gamma () 1)\n(defun caller () (gamma))\n")
    ("go" "Delta" "d.go" 2
     "package sample\nfunc Delta() int { return 1 }\nfunc Caller() int { return Delta() }\n")
    ("rust" "epsilon" "e.rs" 1
     "fn epsilon() -> i32 { 1 }\nfn caller() -> i32 { epsilon() }\n"))
  "Deterministic five-language semantic fixture definitions.")

(defun chat-quality-reliability--run-test (name)
  "Run ERT test NAME and return a bounded result alist."
  (ert-run-tests-batch name)
  (let* ((test (ert-get-test name))
         (result (ert-test-most-recent-result test))
         (passed (and result (ert-test-passed-p result))))
    `((test . ,(symbol-name name))
      (passed . ,(if passed t :json-false)))))

(defun chat-quality-reliability--validate-scenarios ()
  "Fail before measurement when a directed scenario is not loaded."
  (dolist (group chat-coding-acceptance-quality-scenarios)
    (dolist (test-name (cddr group))
      (unless (ert-test-boundp test-name)
        (error "Quality scenario is unavailable: %s/%s"
               (car group) test-name)))))

(defun chat-quality-reliability--await-map (root)
  "Refresh ROOT and return its terminal repository-map result."
  (let ((deadline (+ (float-time) 10.0)) result)
    (chat-repo-map-refresh-async root (lambda (value) (setq result value)))
    (while (and (null result) (< (float-time) deadline))
      (accept-process-output nil 0.005))
    (or result (error "Semantic repository map timed out"))))

(defun chat-quality-reliability--semantic-corpus ()
  "Measure definition, reference, and Top-5 counts by language."
  (let* ((root (expand-file-name "semantic/" chat-quality-reliability--state))
         (chat-code-intel--active-indexes (make-hash-table :test 'equal))
         (chat-repo-map--cache (make-hash-table :test 'equal))
         rows index)
    (make-directory root t)
    (dolist (fixture chat-quality-reliability--semantic-fixtures)
      (with-temp-file (expand-file-name (nth 2 fixture) root)
        (insert (nth 4 fixture))))
    (setq index (chat-code-intel-index-project root))
    (chat-quality-reliability--await-map root)
    (dolist (fixture chat-quality-reliability--semantic-fixtures)
      (let* ((language (nth 0 fixture))
             (symbol (nth 1 fixture))
             (path (file-truename (expand-file-name (nth 2 fixture) root)))
             (definition-line (nth 3 fixture))
             (definitions (chat-code-intel-find-definition index symbol))
             (references (chat-code-intel-find-references index symbol))
             (definition-hit
              (and (= (length definitions) 1)
                   (equal path (file-truename
                                (chat-code-symbol-file (car definitions))))
                   (= definition-line
                      (chat-code-symbol-line (car definitions)))))
             (reference-true
              (cl-count-if
               (lambda (reference)
                 (and (equal path
                             (file-truename
                              (chat-code-reference-file reference)))
                      (> (chat-code-reference-line reference) 1)))
               references))
             (query
              (chat-repo-map-query
               root (list :query symbol :focus-file path
                          :token-budget 2000 :limit 5)))
             (top-five-hit
              (member path
                      (mapcar (lambda (item) (plist-get item :path))
                              (plist-get query :items)))))
        (push `((language . ,language)
                (definitionExpected . 1)
                (definitionHits . ,(if definition-hit 1 0))
                (referenceExpected . 1)
                (referenceReturned . ,(length references))
                (referenceTrue . ,reference-true)
                (topFiveQueries . 1)
                (topFiveHits . ,(if top-five-hit 1 0)))
              rows)))
    (chat-repo-map-discard root)
    (vconcat (nreverse rows))))

(defun chat-quality-reliability--review-corpus ()
  "Return deterministic raw Review finding sets."
  '((expectedCriticalHigh . ["c1" "h1" "h2" "c2" "h3" "h4" "c3"])
    (reportedFormal . ["c1" "h1" "h2" "c2" "h3" "h4" "c3"
                       "low-noise"])))

(defun chat-quality-reliability--prompt-samples ()
  "Measure plan plus active work-note share across 20 growing turns."
  (let* ((chat-work-context--stores (make-hash-table :test 'equal))
         (chat-work-context--indexes (make-hash-table :test 'equal))
         (session (chat-session-create "Quality prompt" 'fixture))
         (session-id (chat-session-id session))
         (task-id "quality-task")
         samples)
    (chat-session-metadata-set session 'code-enabled t)
    (chat-session-metadata-set session 'activeTaskId task-id)
    (chat-work-plan-create
     session "Measure bounded context"
     '(((id . "inspect") (title . "Inspect context")
        (acceptance . "Context is measured"))
       ((id . "verify") (title . "Verify budget")
        (dependencies . ["inspect"]) (acceptance . "Budget passes"))))
    (chat-work-note-upsert
     session-id "next-step" '((action . "measure prompt"))
     :task-id task-id :kind 'next-step :scope 'task :scope-id task-id
     :source-id "quality:prompt")
    (let* ((plan (chat-work-plan-context-fragment session task-id))
           (notes
            (chat-work-note-fragments
             session-id (list :session-id session-id :task-id task-id)))
           (plan-tokens
            (chat-context-count-tokens
             (chat-context-fragment-payload plan)))
           (note-tokens
            (chat-context-count-tokens
             (mapconcat #'chat-context-fragment-payload notes "\n")))
           (system-tokens
            (chat-context-count-tokens
             (chat-tool-caller-build-system-prompt
              (chat-code--compose-system-prompt))))
           (schema-tokens
            (chat-context-count-tokens
             (json-encode (chat-tool-caller-provider-tools)))))
      (dotimes (index 20)
        (chat-session-add-message
         session
         (make-chat-message
          :id (format "quality-user-%d" index) :role :user
          :content (format "turn %d %s" index (make-string 240 ?u))))
        (chat-session-add-message
         session
         (make-chat-message
          :id (format "quality-assistant-%d" index) :role :assistant
          :content (format "result %d %s" index (make-string 240 ?a))))
        (let* ((message-tokens
                (chat-context-total-tokens (chat-session-messages session)))
               (input-tokens
                (+ system-tokens schema-tokens plan-tokens note-tokens
                   message-tokens))
               (ratio
                (/ (float (+ plan-tokens note-tokens)) input-tokens)))
          (push `((turn . ,(1+ index))
                  (planTokens . ,plan-tokens)
                  (workNoteTokens . ,note-tokens)
                  (inputTokens . ,input-tokens)
                  (ratio . ,ratio))
                samples))))
    (vconcat (nreverse samples))))

(defun chat-quality-reliability--revision ()
  "Return the exact measured Git revision."
  (string-trim
   (with-temp-buffer
     (unless (zerop (process-file "git" nil t nil "rev-parse" "HEAD"))
       (error "Cannot resolve implementation revision"))
     (buffer-string))))

(defun chat-quality-reliability--tree-clean-p ()
  "Return non-nil when the measured Git worktree has no local changes."
  (string-empty-p
   (with-temp-buffer
     (unless (zerop (process-file "git" nil t nil "status" "--porcelain"))
       (error "Cannot inspect implementation worktree"))
     (string-trim (buffer-string)))))

(defun chat-quality-reliability--gate-record (gate)
  "Return the bounded JSON representation of acceptance GATE."
  `((name . ,(chat-coding-acceptance-gate-name gate))
    (status . ,(symbol-name (chat-coding-acceptance-gate-status gate)))
    (expected . ,(chat-coding-acceptance-gate-expected gate))
    (actual . ,(chat-coding-acceptance-gate-actual gate))))

(unwind-protect
    (progn
      (chat-quality-reliability--validate-scenarios)
      (let* ((semantic-corpus (chat-quality-reliability--semantic-corpus))
           (review-corpus (chat-quality-reliability--review-corpus))
           (prompt-samples (chat-quality-reliability--prompt-samples))
           (semantic
            (chat-coding-acceptance--semantic-summary semantic-corpus))
           (review (chat-coding-acceptance--review-summary review-corpus))
           (prompt-median
            (chat-coding-acceptance--plan-note-samples-median prompt-samples))
           (facts
            `((semantic . ,semantic)
              (review . ,review)
              (planWorkNotePromptMedianRatio . ,prompt-median)))
           (evidence
            `((semanticCorpus . ,semantic-corpus)
              (reviewCorpus . ,review-corpus)
              (planWorkNotePromptMedianRatio
               . ((samples . ,prompt-samples)))))
           all-passed)
      (setq all-passed (and semantic review prompt-median t))
      (dolist (group chat-coding-acceptance-quality-scenarios)
        (let ((results
               (mapcar #'chat-quality-reliability--run-test (cddr group))))
          (unless (cl-every
                   (lambda (result) (eq t (alist-get 'passed result)))
                   results)
            (setq all-passed nil))
          (setq evidence
                (append evidence (list (cons (car group) (vconcat results)))))))
      (let* ((metadata
              `((qualityReliability . ,facts) (evidence . ,evidence)))
             (tree-clean (chat-quality-reliability--tree-clean-p))
             (gates (chat-coding-acceptance-quality-gates metadata))
             (gates-pass
              (cl-every
               (lambda (gate)
                 (eq 'passed (chat-coding-acceptance-gate-status gate)))
               gates))
             (allow-dirty
              (equal "1" (getenv "CHAT_QUALITY_ALLOW_DIRTY")))
             (record
              `((schemaVersion . 1)
                (implementationRevision .
                                        ,(chat-quality-reliability--revision))
                (implementationTreeClean . ,(if tree-clean t :json-false))
                (measuredAt . ,(format-time-string "%FT%T%z"))
                (qualityReliability . ,facts)
                (acceptanceGates
                 . ,(vconcat
                     (mapcar #'chat-quality-reliability--gate-record gates)))
                (evidence . ,evidence)))
             (json-encoding-pretty-print t)
             (encoded (json-encode record))
             (output
              (or (getenv "CHAT_QUALITY_RELIABILITY_OUTPUT")
                  (getenv "CHAT_QUALITY_OUTPUT"))))
        (unless (and gates-pass (or tree-clean allow-dirty))
          (setq all-passed nil))
        (when output
          (make-directory (file-name-directory (expand-file-name output)) t)
          (with-temp-file output (insert encoded "\n")))
        (princ encoded)
        (princ "\n")
        (unless all-passed (kill-emacs 1)))))
  (when (file-directory-p chat-quality-reliability--state)
    (delete-directory chat-quality-reliability--state t)))

;;; run-quality-reliability.el ends here
