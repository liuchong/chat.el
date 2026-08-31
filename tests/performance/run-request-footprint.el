;;; run-request-footprint.el --- Offline provider request footprint gate -*- lexical-binding: t; -*-

;;; Commentary:

;; Capture the first real Agent request immediately before transport and compare
;; its message plus provider-tool JSON footprint with the frozen M9 baseline.
;; Run with:
;;   emacs -Q --batch -l tests/test-paths.el \
;;     -l tests/performance/run-request-footprint.el

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'chat)
(require 'chat-coding-eval)

(defconst chat-request-footprint--project-root
  (file-name-as-directory
   (file-truename
    (expand-file-name "../.." (file-name-directory load-file-name)))))

(defconst chat-request-footprint--baseline-path
  (expand-file-name
   "tests/fixtures/coding-eval/request-footprint-baseline.json"
   chat-request-footprint--project-root))

(defun chat-request-footprint--git-output (&rest args)
  "Return trimmed Git output for ARGS in the implementation checkout."
  (let ((default-directory chat-request-footprint--project-root))
    (with-temp-buffer
      (unless (zerop (apply #'process-file "git" nil t nil args))
        (error "Git command failed: %s" (string-join args " ")))
      (string-trim (buffer-string)))))

(defun chat-request-footprint--read-json (path)
  "Read one JSON object from PATH."
  (with-temp-buffer
    (insert-file-contents path)
    (json-parse-buffer :object-type 'alist :array-type 'list
                       :null-object nil :false-object :json-false)))

(defun chat-request-footprint--message-bytes (messages)
  "Return content bytes across typed MESSAGES."
  (apply #'+
         (mapcar (lambda (message)
                   (string-bytes (or (chat-message-content message) "")))
                 messages)))

(defun chat-request-footprint--tool-record (tool)
  "Return bounded byte metrics for provider TOOL."
  (let* ((function (alist-get 'function tool))
         (description (or (alist-get 'description function) ""))
         (parameters (alist-get 'parameters function)))
    `((name . ,(alist-get 'name function))
      (bytes . ,(string-bytes (json-encode tool)))
      (descriptionBytes . ,(string-bytes description))
      (schemaBytes . ,(string-bytes (json-encode parameters))))))

(defun chat-request-footprint--measure ()
  "Return the current first-request footprint without network access."
  (let* ((root (make-temp-file "chat-request-footprint-" t))
         (default-directory chat-request-footprint--project-root)
         (fixture-root (expand-file-name "tests/fixtures/coding-eval/"
                                         default-directory))
         (suite (chat-coding-eval-load-suite
                 (expand-file-name "manifest.json" fixture-root)))
         (task (seq-find
                (lambda (item)
                  (equal "elisp-single-fix"
                         (chat-coding-eval-task-id item)))
                suite))
         (workspace (expand-file-name "workspace/" root))
         (chat-session-directory (expand-file-name "sessions/" root))
         (chat-task-directory (expand-file-name "tasks/" root))
         (chat-eval-directory (expand-file-name "evaluations/" root))
         (chat-code-intel-index-directory (expand-file-name "index/" root))
         (chat-session-auto-save nil)
         (chat-task-auto-save nil)
         captured-messages
         captured-options)
    (unwind-protect
        (progn
          (copy-directory
           (expand-file-name (chat-coding-eval-task-fixture-directory task)
                             fixture-root)
           workspace nil nil t)
          (let* ((session
                  (chat-session-create "Request footprint" 'deepseek
                                       "deepseek-v4-flash"))
                 (prompt
                  (format
                   (concat "%s\n\nWork only inside the current workspace. "
                           "The only paths you may change are: %s. "
                           "Finish with a concise answer describing the result.%s")
                   (chat-coding-eval-task-prompt task)
                   (string-join (chat-coding-eval-task-allowed-paths task) ", ")
                   (chat-coding-eval--verification-guidance task))))
            (chat-session-set-working-directory session workspace)
            (chat-code-enable session workspace)
            (setf (chat-session-approval-mode session) 'guarded)
            (cl-letf (((symbol-function 'chat-model-request-events)
                       (lambda (_provider messages callback options)
                         (setq captured-messages messages
                               captured-options options)
                         (funcall
                          callback
                          (chat-model-event-create
                           :type 'completed
                           :payload '(:result (:content "done"
                                              :reasoning ""))))
                         'request-footprint-handle)))
              (chat-agent-start
               (list
                :provider 'deepseek
                :model "deepseek-v4-flash"
                :messages
                (list (make-chat-message
                       :id "request-footprint-user" :role :user
                       :content prompt :timestamp (current-time)))
                :session session :profile 'code :project-root workspace
                :transport 'stream))))
          (let* ((tools (append (plist-get captured-options :tools) nil))
                 (message-bytes
                  (chat-request-footprint--message-bytes captured-messages))
                 (tool-bytes (string-bytes (json-encode (vconcat tools))))
                 (records (mapcar #'chat-request-footprint--tool-record tools)))
            `((taskId . ,(chat-coding-eval-task-id task))
              (authorizedToolCount . ,(length chat-capability-programming-tools))
              (messageCount . ,(length captured-messages))
              (messageBytes . ,message-bytes)
              (toolCount . ,(length tools))
              (toolBytes . ,tool-bytes)
              (combinedBytes . ,(+ message-bytes tool-bytes))
              (tools . ,(vconcat
                         (sort records
                               (lambda (left right)
                                 (> (alist-get 'bytes left)
                                    (alist-get 'bytes right)))))))))
      (when (file-directory-p root)
        (delete-directory root t)))))

(defun chat-request-footprint-run ()
  "Measure, report and enforce the frozen first-request footprint gate."
  (let* ((baseline (chat-request-footprint--read-json
                    chat-request-footprint--baseline-path))
         (measurement (chat-request-footprint--measure))
         (baseline-bytes (alist-get 'combinedBytes baseline))
         (current-bytes (alist-get 'combinedBytes measurement))
         (ratio (/ (float current-bytes) baseline-bytes))
         (limit (alist-get 'maxCombinedRatio baseline))
         (passed (<= ratio limit))
         (record
          `((schemaVersion . 1)
            (implementationRevision .
                                    ,(chat-request-footprint--git-output
                                      "rev-parse" "HEAD"))
            (implementationTreeClean .
                                     ,(if (string-empty-p
                                           (chat-request-footprint--git-output
                                            "status" "--porcelain"))
                                          t :json-false))
            (measuredAt . ,(format-time-string "%FT%T%z"))
            (metric . ,(alist-get 'metric baseline))
            (baselineRevision . ,(alist-get 'baselineRevision baseline))
            (baselineCombinedBytes . ,baseline-bytes)
            (maxCombinedRatio . ,limit)
            (currentCombinedBytes . ,current-bytes)
            (currentRatio . ,ratio)
            (passed . ,(if passed t :json-false))
            (measurement . ,measurement)))
         (output (getenv "CHAT_REQUEST_FOOTPRINT_OUTPUT"))
         (json-encoding-pretty-print t)
         (text (concat (json-encode record) "\n")))
    (if output
        (progn
          (make-directory (file-name-directory (expand-file-name output)) t)
          (with-temp-file output (insert text)))
      (princ text))
    passed))

(condition-case err
    (kill-emacs (if (chat-request-footprint-run) 0 1))
  (error
   (message "Request footprint gate failed: %s" (error-message-string err))
   (kill-emacs 2)))

;;; run-request-footprint.el ends here
