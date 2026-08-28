;;; chat-code-review.el --- Typed independent code review -*- lexical-binding: t; -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;;; Commentary:

;; Independent review sessions receive bounded repository evidence and a
;; read-only capability profile.  Their output is parsed into strict findings
;; that can be persisted as lifecycle facts and navigated in Emacs.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)
(require 'chat-event)
(require 'chat-session)
(require 'chat-task)

(defgroup chat-code-review nil
  "Independent typed code review."
  :group 'chat)

(defcustom chat-code-review-diff-limit 120000
  "Maximum diff characters supplied to one reviewer."
  :type 'integer
  :group 'chat-code-review)

(defcustom chat-code-review-evidence-limit 24000
  "Maximum repo-map or verification evidence characters per section."
  :type 'integer
  :group 'chat-code-review)

(defcustom chat-code-review-verify-high-severity t
  "Whether critical and high findings receive an independent verdict."
  :type 'boolean
  :group 'chat-code-review)

(define-error 'chat-code-review-invalid "Invalid structured review output")

(cl-defstruct (chat-code-review-finding
               (:constructor chat-code-review-finding-create))
  id severity original-severity path line title evidence recommendation
  status verifier-id)

(cl-defstruct (chat-code-review-result
               (:constructor chat-code-review-result-create))
  id session-id task-id project-root objective base-revision status findings
  verification-id created-at completed-at error)

(defvar chat-code-review--results (make-hash-table :test 'equal)
  "Review results keyed by stable id.")

(defvar chat-code-review-start-agent-function #'chat-subagent-start-agent
  "Function used to launch isolated review agents.")

(defvar chat--current-session)

(defvar-local chat-code-review--view-result nil)

(defun chat-code-review--now-ms ()
  "Return the current time in milliseconds."
  (floor (* 1000 (float-time))))

(defun chat-code-review--new-id (prefix)
  "Return a fresh identifier with PREFIX."
  (chat-session-new-message-id prefix))

(defun chat-code-review--bounded (value limit)
  "Return VALUE bounded to LIMIT characters."
  (let ((text (if (stringp value) value (prin1-to-string value))))
    (if (> (length text) limit)
        (concat (substring text 0 limit) "\n[truncated]")
      text)))

(defun chat-code-review--git (root &rest arguments)
  "Run read-only Git ARGUMENTS in ROOT and return stdout."
  (let ((default-directory (file-name-as-directory (expand-file-name root))))
    (with-temp-buffer
      (let ((exit (apply #'process-file "git" nil t nil arguments)))
        (unless (zerop exit)
          (error "git %s failed: %s"
                 (string-join arguments " ")
                 (string-trim (buffer-string))))
        (string-trim-right (buffer-string))))))

(defun chat-code-review-project-root (directory)
  "Return the canonical Git root containing DIRECTORY."
  (file-name-as-directory
   (file-truename
    (chat-code-review--git directory "rev-parse" "--show-toplevel"))))

(defun chat-code-review-read-diff (project-root &optional base-revision)
  "Return a bounded diff in PROJECT-ROOT from BASE-REVISION."
  (let* ((root (chat-code-review-project-root project-root))
         (base (or base-revision "HEAD")))
    (chat-code-review--bounded
     (chat-code-review--git root "diff" "--binary" base "--")
     chat-code-review-diff-limit)))

(defun chat-code-review-read-repo-map (project-root query &optional changed)
  "Return bounded ranked repo-map evidence for QUERY and CHANGED files."
  (require 'chat-repo-map)
  (chat-code-review--bounded
   (chat-repo-map-query
    (chat-code-review-project-root project-root)
    (list :query query :changed-files changed :limit 20 :token-budget 3000))
   chat-code-review-evidence-limit))

(defun chat-code-review--field (object name)
  "Read NAME from JSON alist OBJECT."
  (or (alist-get name object)
      (alist-get (symbol-name name) object nil nil #'equal)))

(defun chat-code-review--required-text (object field)
  "Return required nonblank FIELD from OBJECT."
  (let ((value (chat-code-review--field object field)))
    (unless (and (stringp value) (not (string-blank-p value)))
      (signal 'chat-code-review-invalid
              (list (format "missing or blank %s" field))))
    value))

(defun chat-code-review--severity (value)
  "Normalize and validate finding severity VALUE."
  (let ((severity (and (stringp value) (intern (downcase value)))))
    (unless (memq severity '(critical high medium low))
      (signal 'chat-code-review-invalid
              (list (format "invalid severity: %S" value))))
    severity))

(defun chat-code-review--canonical-path (root value)
  "Return canonical relative VALUE beneath ROOT."
  (unless (and (stringp value) (not (string-blank-p value)))
    (signal 'chat-code-review-invalid (list "missing path")))
  (let* ((root (file-name-as-directory (file-truename root)))
         (absolute (expand-file-name value root)))
    (unless (file-in-directory-p absolute root)
      (signal 'chat-code-review-invalid
              (list (format "finding path escapes project: %s" value))))
    (file-relative-name absolute root)))

(defun chat-code-review--json-object (value)
  "Decode VALUE into a JSON object alist."
  (if (stringp value)
      (let* ((start (string-match "{" value))
             (end (and start (cl-position ?} value :from-end t))))
        (unless (and start end)
          (signal 'chat-code-review-invalid (list "missing JSON object")))
        (condition-case err
            (json-parse-string
             (substring value start (1+ end))
             :object-type 'alist :array-type 'list
             :null-object nil :false-object nil)
          (error
           (signal 'chat-code-review-invalid
                   (list (error-message-string err))))))
    value))

(defun chat-code-review-parse (value project-root)
  "Parse strict review VALUE for PROJECT-ROOT into typed findings."
  (let* ((object (chat-code-review--json-object value))
         (raw (chat-code-review--field object 'findings))
         (seen (make-hash-table :test 'equal))
         findings)
    (unless (listp raw)
      (signal 'chat-code-review-invalid (list "findings must be an array")))
    (dolist (item raw)
      (let* ((path (chat-code-review--canonical-path
                    project-root (chat-code-review--field item 'path)))
             (line (chat-code-review--field item 'line))
             (title (chat-code-review--required-text item 'title))
             (evidence (chat-code-review--required-text item 'evidence))
             (severity (chat-code-review--severity
                        (chat-code-review--field item 'severity)))
             (key (list path line (downcase title))))
        (unless (and (integerp line) (> line 0))
          (signal 'chat-code-review-invalid
                  (list (format "invalid line for %s" path))))
        (when (gethash key seen)
          (signal 'chat-code-review-invalid
                  (list (format "duplicate finding at %s:%s" path line))))
        (puthash key t seen)
        (push
         (chat-code-review-finding-create
          :id (or (chat-code-review--field item 'id)
                  (chat-code-review--new-id "finding"))
          :severity severity :original-severity severity
          :path path :line line :title title :evidence evidence
          :recommendation (chat-code-review--field item 'recommendation)
          :status 'open)
         findings)))
    (nreverse findings)))

(defun chat-code-review-apply-verdict (finding value)
  "Apply a constrained verifier VALUE to FINDING.

The verifier may confirm, downgrade, or reject.  It cannot change the path,
line, title, evidence, or original severity."
  (let* ((object (chat-code-review--json-object value))
         (id (chat-code-review--required-text object 'finding_id))
         (decision-text (chat-code-review--required-text object 'decision))
         (decision (intern (downcase decision-text)))
         (severity-value (chat-code-review--field object 'severity))
         (rank '((critical . 4) (high . 3) (medium . 2) (low . 1))))
    (unless (equal id (chat-code-review-finding-id finding))
      (signal 'chat-code-review-invalid (list "verifier finding_id mismatch")))
    (unless (memq decision '(confirm downgrade reject))
      (signal 'chat-code-review-invalid (list "invalid verifier decision")))
    (pcase decision
      ('confirm (setf (chat-code-review-finding-status finding) 'confirmed))
      ('reject (setf (chat-code-review-finding-status finding) 'rejected))
      ('downgrade
       (let ((severity (chat-code-review--severity severity-value)))
         (unless (< (alist-get severity rank)
                    (alist-get (chat-code-review-finding-original-severity
                                finding) rank))
           (signal 'chat-code-review-invalid
                   (list "verifier may only lower severity")))
         (setf (chat-code-review-finding-severity finding) severity
               (chat-code-review-finding-status finding) 'downgraded))))
    finding))

(defun chat-code-review--finding-data (finding)
  "Return durable bounded data for FINDING."
  `((id . ,(chat-code-review-finding-id finding))
    (severity . ,(symbol-name (chat-code-review-finding-severity finding)))
    (originalSeverity . ,(symbol-name
                          (chat-code-review-finding-original-severity finding)))
    (path . ,(chat-code-review-finding-path finding))
    (line . ,(chat-code-review-finding-line finding))
    (title . ,(chat-code-review--bounded
               (chat-code-review-finding-title finding) 300))
    (evidence . ,(chat-code-review--bounded
                  (chat-code-review-finding-evidence finding) 1200))
    (status . ,(symbol-name (chat-code-review-finding-status finding)))))

(defun chat-code-review-result-data (result)
  "Return the durable public projection for RESULT."
  `((id . ,(chat-code-review-result-id result))
    (status . ,(symbol-name (chat-code-review-result-status result)))
    (projectRoot . ,(chat-code-review-result-project-root result))
    (baseRevision . ,(chat-code-review-result-base-revision result))
    (verificationId . ,(chat-code-review-result-verification-id result))
    (findings . ,(mapcar #'chat-code-review--finding-data
                         (chat-code-review-result-findings result)))))

(defun chat-code-review--emit (type result &optional finding)
  "Emit bounded review TYPE for RESULT and optional FINDING."
  (chat-event-emit
   type :session-id (chat-code-review-result-session-id result)
   :task-id (chat-code-review-result-task-id result)
   :source 'code-review :subject result
   :payload
   (if finding
       `((review_id . ,(chat-code-review-result-id result))
         (finding_id . ,(chat-code-review-finding-id finding))
         (severity . ,(symbol-name
                       (chat-code-review-finding-severity finding)))
         (path . ,(chat-code-review-finding-path finding))
         (line . ,(chat-code-review-finding-line finding))
         (title . ,(chat-code-review--bounded
                    (chat-code-review-finding-title finding) 200))
         (evidence_digest . ,(secure-hash
                              'sha256
                              (chat-code-review-finding-evidence finding)))
         (status . ,(symbol-name (chat-code-review-finding-status finding))))
     `((review_id . ,(chat-code-review-result-id result))
       (status . ,(symbol-name (chat-code-review-result-status result)))
       (finding_count . ,(length (chat-code-review-result-findings result)))))))

(defun chat-code-review-build-prompt
    (objective base-revision diff repo-map verification)
  "Build one bounded independent review prompt from explicit evidence."
  (format
   (concat
    "Review the supplied change independently. You have read-only tools. "
    "Do not edit files or run commands with write effects. Return exactly one "
    "JSON object: {\"findings\":[{\"id\":\"stable-id\","
    "\"severity\":\"critical|high|medium|low\",\"path\":\"relative/path\","
    "\"line\":1,\"title\":\"...\",\"evidence\":\"...\","
    "\"recommendation\":\"...\"}]}. Use an empty array when there are no "
    "actionable defects. Every finding must identify a changed-file line and "
    "concrete evidence.\n\nOBJECTIVE\n%s\n\nBASE REVISION\n%s\n\nDIFF\n%s"
    "\n\nREPO MAP\n%s\n\nVERIFICATION EVIDENCE\n%s")
   (chat-code-review--bounded objective 8000)
   base-revision
   (chat-code-review--bounded diff chat-code-review-diff-limit)
   (chat-code-review--bounded repo-map chat-code-review-evidence-limit)
   (chat-code-review--bounded verification chat-code-review-evidence-limit)))

(defun chat-code-review--verifier-prompt (finding)
  "Return constrained verifier prompt for FINDING."
  (format
   (concat
    "Independently verify this finding using read-only evidence. Return exactly "
    "{\"finding_id\":\"%s\",\"decision\":\"confirm|downgrade|reject\","
    "\"severity\":\"critical|high|medium|low\"}. Severity is required only "
    "for downgrade. You cannot rewrite the finding.\n\n%s")
   (chat-code-review-finding-id finding)
   (json-serialize (chat-code-review--finding-data finding))))

(defun chat-code-review--finish (result task status &optional error)
  "Finish RESULT and TASK with STATUS and optional ERROR."
  (setf (chat-code-review-result-status result) status
        (chat-code-review-result-error result) error
        (chat-code-review-result-completed-at result) (chat-code-review--now-ms))
  (puthash (chat-code-review-result-id result) result chat-code-review--results)
  (chat-task-transition
   task (if (eq status 'completed) 'completed 'failed)
   :result (and (eq status 'completed) (chat-code-review-result-data result))
   :error error)
  (chat-code-review--emit 'review-completed result)
  result)

(defun chat-code-review--verify-findings
    (result task parent findings complete error-callback)
  "Verify FINDINGS sequentially, then COMPLETE RESULT."
  (if-let* ((finding (car findings)))
      (funcall
       chat-code-review-start-agent-function
       "Review verifier" (chat-code-review--verifier-prompt finding) parent
       (lambda (response)
         (condition-case err
             (progn
               (setf (chat-code-review-finding-verifier-id finding)
                     (chat-code-review--field response 'id))
               (chat-code-review-apply-verdict
                finding (chat-code-review--field response 'summary))
               (chat-code-review--emit 'review-finding result finding)
               (chat-code-review--verify-findings
                result task parent (cdr findings) complete error-callback))
           (error
            (let ((message (error-message-string err)))
              (chat-code-review--finish result task 'failed message)
              (funcall error-callback message)))))
       (lambda (message)
         (chat-code-review--finish result task 'failed message)
         (funcall error-callback message))
       4 '(:profile review))
    (chat-code-review--finish result task 'completed)
    (funcall complete result)))

(cl-defun chat-code-review-start
    (parent-session objective &key project-root base-revision diff repo-map
                    verification verification-id
                    (verify-high chat-code-review-verify-high-severity)
                    on-complete on-error)
  "Start an independent typed review for OBJECTIVE in PROJECT-ROOT."
  (let* ((root (chat-code-review-project-root
                (or project-root
                    (chat-session-working-directory parent-session))))
         (base (or base-revision
                   (chat-code-review--git root "rev-parse" "HEAD")))
         (diff (or diff (chat-code-review-read-diff root base)))
         (repo-map (or repo-map
                       (chat-code-review-read-repo-map root objective)))
         (verification (or verification "No verification evidence supplied."))
         (id (chat-code-review--new-id "review"))
         (task
          (chat-task-adopt
           :id id :kind 'review :title "Independent code review"
           :status 'queued :session-id (chat-session-id parent-session)
           :source 'code-review
           :resources (list (list :key (concat "path:" root) :mode 'read))
           :payload `((baseRevision . ,base)
                      (verificationId . ,verification-id))))
         (result
          (chat-code-review-result-create
           :id id :session-id (chat-session-id parent-session) :task-id id
           :project-root root :objective objective :base-revision base
           :status 'running :verification-id verification-id
           :created-at (chat-code-review--now-ms))))
    (puthash id result chat-code-review--results)
    (chat-task-transition task 'running)
    (chat-code-review--emit 'review-started result)
    (funcall
     chat-code-review-start-agent-function
     "Read-only code review"
     (chat-code-review-build-prompt objective base diff repo-map verification)
     parent-session
     (lambda (response)
       (condition-case err
           (let ((findings
                  (chat-code-review-parse
                   (chat-code-review--field response 'summary) root)))
             (setf (chat-code-review-result-findings result) findings)
             (dolist (finding findings)
               (chat-code-review--emit 'review-finding result finding))
             (let ((high
                    (and verify-high
                         (seq-filter
                          (lambda (finding)
                            (memq (chat-code-review-finding-severity finding)
                                  '(critical high)))
                          findings))))
               (if high
                   (chat-code-review--verify-findings
                    result task parent-session high
                    (or on-complete #'ignore) (or on-error #'ignore))
                 (chat-code-review--finish result task 'completed)
                 (when on-complete (funcall on-complete result)))))
         (error
          (let ((message (error-message-string err)))
            (chat-code-review--finish result task 'failed message)
            (when on-error (funcall on-error message))))))
     (lambda (message)
       (chat-code-review--finish result task 'failed message)
       (when on-error (funcall on-error message)))
     8 '(:profile review))
    result))

(defun chat-code-review-get (id)
  "Return review result ID."
  (gethash id chat-code-review--results))

(defun chat-code-review-list (&optional session-id)
  "Return review results, optionally restricted to SESSION-ID."
  (let (items)
    (maphash
     (lambda (_ result)
       (when (or (null session-id)
                 (equal session-id (chat-code-review-result-session-id result)))
         (push result items)))
     chat-code-review--results)
    (sort items (lambda (a b)
                  (> (chat-code-review-result-created-at a)
                     (chat-code-review-result-created-at b))))))

(defun chat-code-review-score (actual expected)
  "Return precision and recall for ACTUAL and EXPECTED finding ids."
  (let* ((actual (delete-dups (copy-sequence actual)))
         (expected (delete-dups (copy-sequence expected)))
         (true (cl-count-if (lambda (id) (member id expected)) actual)))
    (list :precision (if actual (/ (float true) (length actual)) 1.0)
          :recall (if expected (/ (float true) (length expected)) 1.0)
          :true-positive true :reported (length actual)
          :expected (length expected))))

(defun chat-code-review--entries ()
  "Return tabulated entries for the current review view."
  (mapcar
   (lambda (finding)
     (list finding
           (vector
            (upcase (symbol-name (chat-code-review-finding-severity finding)))
            (format "%s:%d" (chat-code-review-finding-path finding)
                    (chat-code-review-finding-line finding))
            (chat-code-review-finding-title finding)
            (symbol-name (chat-code-review-finding-status finding)))))
   (chat-code-review-result-findings chat-code-review--view-result)))

(define-derived-mode chat-code-review-view-mode tabulated-list-mode "Review"
  "Major mode for typed review findings."
  (setq tabulated-list-format
        [("Severity" 10 t) ("Location" 40 t) ("Finding" 72 t)
         ("Status" 12 t)])
  (setq tabulated-list-padding 2
        tabulated-list-entries #'chat-code-review--entries)
  (tabulated-list-init-header))

(defun chat-code-review-jump ()
  "Jump from the finding at point to its source line."
  (interactive)
  (let ((finding (tabulated-list-get-id)))
    (unless (chat-code-review-finding-p finding)
      (user-error "No review finding at point"))
    (find-file
     (expand-file-name (chat-code-review-finding-path finding)
                       (chat-code-review-result-project-root
                        chat-code-review--view-result)))
    (goto-char (point-min))
    (forward-line (1- (chat-code-review-finding-line finding)))))

(define-key chat-code-review-view-mode-map (kbd "RET") #'chat-code-review-jump)

(defun chat-code-review-open (result)
  "Open typed review RESULT in a native Emacs view."
  (interactive
   (list (or (car (chat-code-review-list))
             (user-error "No review results"))))
  (let ((buffer (get-buffer-create "*chat-code-review*")))
    (with-current-buffer buffer
      (chat-code-review-view-mode)
      (setq chat-code-review--view-result result)
      (tabulated-list-revert))
    (pop-to-buffer buffer)))

(defun chat-code-review-current-changes ()
  "Review current project changes and open the typed findings view."
  (interactive)
  (let ((session (or (and (boundp 'chat--current-session)
                          chat--current-session)
                     (error "No active chat session"))))
    (chat-code-review-start
     session "Review the current working tree changes"
     :project-root default-directory
     :on-complete #'chat-code-review-open
     :on-error (lambda (message)
                 (message "Code review failed: %s" message)))))

(provide 'chat-code-review)
;;; chat-code-review.el ends here
