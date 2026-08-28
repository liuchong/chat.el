;;; chat-eval.el --- Deterministic Agent evaluations -*- lexical-binding: t; -*-

;;; Commentary:

;; Versioned offline scenarios and immutable, bounded result records.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)

(defconst chat-eval-scenario-schema-version 1)
(defconst chat-eval-result-schema-version 1)

(defcustom chat-eval-directory (expand-file-name "evaluations/" "~/.chat/")
  "Directory holding immutable evaluation results."
  :type 'directory :group 'chat)

(defcustom chat-eval-auto-save t
  "Whether evaluation runs persist immutable result records."
  :type 'boolean :group 'chat)

(defcustom chat-eval-max-value-bytes 4096
  "Maximum encoded bytes kept for one expected or actual value."
  :type 'integer :group 'chat)

(defcustom chat-eval-redact-patterns
  '("-----BEGIN [A-Z ]*PRIVATE KEY-----"
    "\\(?:api[_-]?key\\|password\\|secret\\|token\\)[[:space:]]*[:=][[:space:]]*[^[:space:]]\\{8,\\}")
  "Patterns replaced before evaluation values become durable."
  :type '(repeat regexp) :group 'chat)

(defvar chat-eval-clock-function
  (lambda () (round (* 1000 (float-time))))
  "Function returning evaluation time in milliseconds.")

(defvar chat-eval-id-function
  (lambda ()
    (format "eval-%s-%06x"
            (format-time-string "%Y%m%dT%H%M%S%N" nil t)
            (random #x1000000)))
  "Function returning a new evaluation result identifier.")

(cl-defstruct (chat-eval-check
               (:constructor chat-eval-check-create-record))
  name passed expected actual detail)

(cl-defstruct (chat-eval-scenario
               (:constructor chat-eval-scenario-create-record))
  schema-version id revision category description fixture-id fixture tags
  live-p function)

(cl-defstruct (chat-eval-result
               (:constructor chat-eval-result-create-record))
  schema-version id scenario-id scenario-revision category fixture-id
  fixture-digest started-at finished-at duration-ms status checks metadata)

(defvar chat-eval--registry (make-hash-table :test 'equal)
  "Scenario ID to scenario record.")

(defun chat-eval-check (name passed expected actual &optional detail)
  "Return a named evaluation check."
  (chat-eval-check-create-record
   :name (format "%s" name) :passed (and passed t)
   :expected expected :actual actual :detail detail))

(defun chat-eval--validate-scenario (scenario)
  "Validate SCENARIO and return it."
  (unless (chat-eval-scenario-p scenario)
    (error "Not an evaluation scenario"))
  (unless (= (or (chat-eval-scenario-schema-version scenario) 0)
             chat-eval-scenario-schema-version)
    (error "Unsupported evaluation scenario schema: %s"
           (chat-eval-scenario-schema-version scenario)))
  (dolist (field (list (chat-eval-scenario-id scenario)
                       (chat-eval-scenario-category scenario)
                       (chat-eval-scenario-fixture-id scenario)))
    (unless (and (stringp field) (not (string-empty-p field)))
      (error "Evaluation scenario identity fields cannot be empty")))
  (unless (and (integerp (chat-eval-scenario-revision scenario))
               (> (chat-eval-scenario-revision scenario) 0))
    (error "Evaluation scenario revision must be positive"))
  (unless (functionp (chat-eval-scenario-function scenario))
    (error "Evaluation scenario requires an executable"))
  scenario)

(defun chat-eval-register (scenario &optional replace)
  "Register SCENARIO.  REPLACE permits a nondecreasing revision."
  (chat-eval--validate-scenario scenario)
  (let ((old (gethash (chat-eval-scenario-id scenario)
                      chat-eval--registry)))
    (when (and old (not replace))
      (error "Evaluation scenario already exists: %s"
             (chat-eval-scenario-id scenario)))
    (when (and old replace
               (< (chat-eval-scenario-revision scenario)
                  (chat-eval-scenario-revision old)))
      (error "Evaluation scenario revision cannot move backwards")))
  (puthash (chat-eval-scenario-id scenario) scenario chat-eval--registry)
  scenario)

(defun chat-eval-get (id)
  "Return registered scenario ID, or nil."
  (gethash id chat-eval--registry))

(defun chat-eval-scenarios (&optional include-live)
  "Return registered scenarios sorted by ID."
  (let (scenarios)
    (maphash
     (lambda (_id scenario)
       (when (or include-live (not (chat-eval-scenario-live-p scenario)))
         (push scenario scenarios)))
     chat-eval--registry)
    (sort scenarios
          (lambda (left right)
            (string< (chat-eval-scenario-id left)
                     (chat-eval-scenario-id right))))))

(defun chat-eval--fixture-digest (scenario)
  "Return a stable digest for SCENARIO's fixture."
  (secure-hash 'sha256
               (encode-coding-string
                (json-encode (chat-eval-scenario-fixture scenario))
                'utf-8)))

(defun chat-eval--redact-string (value)
  "Return VALUE with credential-like spans redacted."
  (let ((text value))
    (dolist (pattern chat-eval-redact-patterns)
      (setq text (replace-regexp-in-string pattern "[redacted]" text t)))
    text))

(defun chat-eval--sanitize-value (value)
  "Return a bounded, JSON-safe projection of VALUE."
  (let* ((clean
          (cond
           ((stringp value) (chat-eval--redact-string value))
           ((or (numberp value) (eq value t) (null value)) value)
           ((symbolp value) (symbol-name value))
           ((vectorp value)
            (mapcar #'chat-eval--sanitize-value (append value nil)))
           ((listp value)
            (mapcar
             (lambda (entry)
               (if (consp entry)
                   (cons (car entry)
                         (chat-eval--sanitize-value (cdr entry)))
                 (chat-eval--sanitize-value entry)))
             value))
           (t (format "%S" value))))
         (encoded
          (condition-case nil
              (json-encode clean)
            (error (json-encode (format "%S" clean)))))
         (bytes (string-bytes encoded)))
    (if (<= bytes chat-eval-max-value-bytes)
        clean
      `((truncated . t) (originalBytes . ,bytes)))))

(defun chat-eval--normalize-check (check)
  "Validate and sanitize CHECK."
  (unless (chat-eval-check-p check)
    (error "Scenario returned a non-check value"))
  (unless (and (stringp (chat-eval-check-name check))
               (not (string-empty-p (chat-eval-check-name check))))
    (error "Evaluation check name cannot be empty"))
  (setf (chat-eval-check-passed check) (and (chat-eval-check-passed check) t)
        (chat-eval-check-expected check)
        (chat-eval--sanitize-value (chat-eval-check-expected check))
        (chat-eval-check-actual check)
        (chat-eval--sanitize-value (chat-eval-check-actual check))
        (chat-eval-check-detail check)
        (and (chat-eval-check-detail check)
             (chat-eval--redact-string
              (truncate-string-to-width
               (format "%s" (chat-eval-check-detail check)) 512 nil nil t))))
  check)

(defun chat-eval--execute (scenario)
  "Execute SCENARIO and return normalized checks."
  (condition-case err
      (let ((checks (funcall (chat-eval-scenario-function scenario)
                             (chat-eval-scenario-fixture scenario))))
        (unless (listp checks)
          (error "Scenario result must be a list of checks"))
        (mapcar #'chat-eval--normalize-check checks))
    (error
     (list (chat-eval-check
            "scenario-execution" nil "no error"
            (error-message-string err)
            "The scenario raised; other scenarios may continue.")))))

(defun chat-eval--result-file (id)
  "Return the immutable result file for ID."
  (expand-file-name (concat id ".json") chat-eval-directory))

(defun chat-eval--check-to-json (check)
  "Return JSON-friendly data for CHECK."
  `((name . ,(chat-eval-check-name check))
    (passed . ,(if (chat-eval-check-passed check) t :json-false))
    (expected . ,(chat-eval-check-expected check))
    (actual . ,(chat-eval-check-actual check))
    (detail . ,(chat-eval-check-detail check))))

(defun chat-eval--check-from-json (data)
  "Return a check decoded from DATA."
  (chat-eval-check-create-record
   :name (alist-get 'name data)
   :passed (eq t (alist-get 'passed data))
   :expected (alist-get 'expected data)
   :actual (alist-get 'actual data)
   :detail (alist-get 'detail data)))

(defun chat-eval--result-to-json (result)
  "Return JSON-friendly data for RESULT."
  `((schemaVersion . ,(chat-eval-result-schema-version result))
    (id . ,(chat-eval-result-id result))
    (scenarioId . ,(chat-eval-result-scenario-id result))
    (scenarioRevision . ,(chat-eval-result-scenario-revision result))
    (category . ,(chat-eval-result-category result))
    (fixtureId . ,(chat-eval-result-fixture-id result))
    (fixtureDigest . ,(chat-eval-result-fixture-digest result))
    (startedAt . ,(chat-eval-result-started-at result))
    (finishedAt . ,(chat-eval-result-finished-at result))
    (durationMs . ,(chat-eval-result-duration-ms result))
    (status . ,(symbol-name (chat-eval-result-status result)))
    (checks . ,(mapcar #'chat-eval--check-to-json
                       (chat-eval-result-checks result)))
    (metadata . ,(chat-eval--sanitize-value
                  (chat-eval-result-metadata result)))))

(defun chat-eval-to-json-data (result)
  "Return the bounded public JSON projection of RESULT."
  (unless (chat-eval-result-p result)
    (error "Not an evaluation result"))
  (chat-eval--result-to-json result))

(defun chat-eval-export-json (result)
  "Return bounded JSON text for evaluation RESULT."
  (json-encode (chat-eval-to-json-data result)))

(defun chat-eval--result-from-json (data)
  "Return an evaluation result decoded from DATA."
  (let ((version (or (alist-get 'schemaVersion data) 0)))
    (unless (= version chat-eval-result-schema-version)
      (error "Unsupported evaluation result schema: %s" version))
    (chat-eval-result-create-record
     :schema-version version
     :id (alist-get 'id data)
     :scenario-id (alist-get 'scenarioId data)
     :scenario-revision (alist-get 'scenarioRevision data)
     :category (alist-get 'category data)
     :fixture-id (alist-get 'fixtureId data)
     :fixture-digest (alist-get 'fixtureDigest data)
     :started-at (alist-get 'startedAt data)
     :finished-at (alist-get 'finishedAt data)
     :duration-ms (alist-get 'durationMs data)
     :status (intern (alist-get 'status data))
     :checks (mapcar #'chat-eval--check-from-json
                     (alist-get 'checks data))
     :metadata (alist-get 'metadata data))))

(defun chat-eval-save-result (result)
  "Persist RESULT as an immutable atomic record and return it."
  (make-directory chat-eval-directory t)
  (let ((target (chat-eval--result-file (chat-eval-result-id result))))
    (when (file-exists-p target)
      (error "Evaluation result already exists: %s"
             (chat-eval-result-id result)))
    (let ((temp (make-temp-file
                 (expand-file-name ".evaluation-" chat-eval-directory))))
      (unwind-protect
          (progn
            (with-temp-file temp
              (let ((coding-system-for-write 'utf-8))
                (insert (json-encode (chat-eval--result-to-json result)))))
            (rename-file temp target nil))
        (when (file-exists-p temp)
          (delete-file temp)))))
  result)

(cl-defun chat-eval-record-result
    (&key scenario-id scenario-revision category fixture-id fixture-digest
          started-at finished-at status checks metadata id)
  "Create, optionally persist and return one immutable evaluation result.

Identity fields describe the scenario that produced CHECKS.  STATUS defaults
to `passed' only when every normalized check passes.  Callers that run
asynchronously can supply their original STARTED-AT and FINISHED-AT values
without changing the versioned result schema."
  (dolist (field (list scenario-id category fixture-id fixture-digest))
    (unless (and (stringp field) (not (string-empty-p field)))
      (error "Evaluation result identity fields cannot be empty")))
  (unless (and (integerp scenario-revision) (> scenario-revision 0))
    (error "Evaluation result scenario revision must be positive"))
  (unless (listp checks)
    (error "Evaluation result checks must be a list"))
  (let* ((started (or started-at (funcall chat-eval-clock-function)))
         (finished (or finished-at (funcall chat-eval-clock-function)))
         (normalized (mapcar #'chat-eval--normalize-check checks))
         (result
          (chat-eval-result-create-record
           :schema-version chat-eval-result-schema-version
           :id (or id (funcall chat-eval-id-function))
           :scenario-id scenario-id
           :scenario-revision scenario-revision
           :category category
           :fixture-id fixture-id
           :fixture-digest fixture-digest
           :started-at started
           :finished-at finished
           :duration-ms (max 0 (- finished started))
           :status (or status
                       (if (seq-every-p #'chat-eval-check-passed normalized)
                           'passed
                         'failed))
           :checks normalized
           :metadata metadata)))
    (when chat-eval-auto-save
      (chat-eval-save-result result))
    result))

(defun chat-eval-run (scenario-or-id &optional metadata)
  "Run SCENARIO-OR-ID, persist its result and return it."
  (let* ((scenario
          (if (chat-eval-scenario-p scenario-or-id)
              scenario-or-id
            (or (chat-eval-get scenario-or-id)
                (error "Unknown evaluation scenario: %s" scenario-or-id))))
         (_ (chat-eval--validate-scenario scenario))
         (started (funcall chat-eval-clock-function))
         (checks (chat-eval--execute scenario))
         (finished (funcall chat-eval-clock-function)))
    (chat-eval-record-result
     :scenario-id (chat-eval-scenario-id scenario)
     :scenario-revision (chat-eval-scenario-revision scenario)
     :category (chat-eval-scenario-category scenario)
     :fixture-id (chat-eval-scenario-fixture-id scenario)
     :fixture-digest (chat-eval--fixture-digest scenario)
     :started-at started
     :finished-at finished
     :checks checks
     :metadata metadata)))

(defun chat-eval-run-all (&optional include-live)
  "Run every registered scenario, excluding live checks by default."
  (mapcar #'chat-eval-run (chat-eval-scenarios include-live)))

(defun chat-eval-load-result (file-or-id)
  "Load one evaluation result from FILE-OR-ID."
  (let ((file (if (file-name-absolute-p file-or-id)
                  file-or-id
                (chat-eval--result-file file-or-id))))
    (unless (file-exists-p file)
      (error "Evaluation result does not exist: %s" file-or-id))
    (let ((json-object-type 'alist)
          (json-array-type 'list)
          (json-key-type 'symbol))
      (chat-eval--result-from-json (json-read-file file)))))

(defun chat-eval-results (&optional scenario-id)
  "Return persisted results, optionally limited to SCENARIO-ID."
  (let (results)
    (when (file-directory-p chat-eval-directory)
      (dolist (file (directory-files chat-eval-directory t "\\.json\\'"))
        (condition-case nil
            (let ((result (chat-eval-load-result file)))
              (when (or (null scenario-id)
                        (equal scenario-id
                               (chat-eval-result-scenario-id result)))
                (push result results)))
          (error nil))))
    (sort results
          (lambda (left right)
            (if (= (chat-eval-result-started-at left)
                   (chat-eval-result-started-at right))
                (string< (chat-eval-result-id right)
                         (chat-eval-result-id left))
              (> (chat-eval-result-started-at left)
                 (chat-eval-result-started-at right)))))))

(defun chat-eval--check-table (result)
  "Return a name-to-check table for RESULT."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (check (chat-eval-result-checks result))
      (puthash (chat-eval-check-name check) check table))
    table))

(defun chat-eval-compare (left right)
  "Compare result LEFT with RIGHT from the same scenario revision."
  (unless (and (equal (chat-eval-result-scenario-id left)
                      (chat-eval-result-scenario-id right))
               (= (chat-eval-result-scenario-revision left)
                  (chat-eval-result-scenario-revision right)))
    (error "Evaluation comparison requires the same scenario revision"))
  (let ((lt (chat-eval--check-table left))
        (rt (chat-eval--check-table right))
        names changed)
    (maphash (lambda (name _check) (cl-pushnew name names :test #'equal)) lt)
    (maphash (lambda (name _check) (cl-pushnew name names :test #'equal)) rt)
    (dolist (name (sort names #'string<))
      (let ((lc (gethash name lt)) (rc (gethash name rt)))
        (unless (and lc rc
                     (eq (chat-eval-check-passed lc)
                         (chat-eval-check-passed rc))
                     (equal (chat-eval-check-actual lc)
                            (chat-eval-check-actual rc)))
          (push
           (list (cons 'name name)
                 (cons 'leftPassed (and lc (chat-eval-check-passed lc)))
                 (cons 'rightPassed (and rc (chat-eval-check-passed rc)))
                 (cons 'leftActual (and lc (chat-eval-check-actual lc)))
                 (cons 'rightActual (and rc (chat-eval-check-actual rc))))
           changed))))
    `((schemaVersion . ,chat-eval-result-schema-version)
      (scenarioId . ,(chat-eval-result-scenario-id left))
      (scenarioRevision . ,(chat-eval-result-scenario-revision left))
      (statusChanged
       . ,(not (eq (chat-eval-result-status left)
                   (chat-eval-result-status right))))
      (durationDeltaMs
       . ,(- (chat-eval-result-duration-ms right)
             (chat-eval-result-duration-ms left)))
      (changedChecks . ,(nreverse changed)))))

(provide 'chat-eval)
;;; chat-eval.el ends here
