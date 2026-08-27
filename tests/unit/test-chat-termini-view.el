;;; test-chat-termini-view.el --- Tests for Termini views -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'test-helper)
(require 'chat-termini-view)

(defun chat-termini-view-test--client ()
  "Return a ready isolated client."
  (let ((client (chat-termini-client-create :id "view" :command '("termini"))))
    (setf (chat-termini-client-status client) 'ready
          (chat-termini-client-protocol-version client) "2026-07-08"
          (chat-termini-client-methods client) chat-termini-required-methods)
    client))

(defun chat-termini-view-test--session ()
  "Return one session projection."
  (make-chat-termini-session
   :id "rs-1" :display-name "Desk" :cwd "/tmp/work"
   :project-id "project-1" :last-activity-at 1000 :active-job-count 1))

(defun chat-termini-view-test--job (&optional status)
  "Return one job projection with STATUS."
  (make-chat-termini-job
   :id "job-1" :runtime-session-id "rs-1" :kind 'ai :tool "codex"
   :status (or status 'running) :command-preview "inspect changes"
   :duration-ms 42 :exit-code nil))

(ert-deftest termini-session-view-refreshes-through-public-operation ()
  "Session rows are fresh projections from the bridge."
  (let ((client (chat-termini-view-test--client)) called)
    (cl-letf (((symbol-function 'chat-termini-session-list)
               (lambda (actual-client &optional _params)
                 (setq called actual-client)
                 (list (chat-termini-view-test--session)))))
      (with-temp-buffer
        (termini-session-view-mode)
        (setq termini-view-client client)
        (termini-session-view-refresh)
        (should (eq client called))
        (should (equal "rs-1" (caar tabulated-list-entries)))
        (should (equal (chat-termini-session-id
                        (gethash "rs-1" termini-session-view-items))
                       "rs-1"))))))

(ert-deftest termini-session-create-uses-the-declared-open-mode ()
  "Create sends explicit name and cwd without touching Termini files."
  (let ((client (chat-termini-view-test--client)) seen)
    (cl-letf (((symbol-function 'chat-termini-session-open)
               (lambda (_client params) (setq seen params)
                 '((runtimeSessionId . "rs-new")))))
      (should (equal "rs-new"
                     (termini-session-create client "New" "/tmp"))))
    (should (equal "create" (alist-get 'mode seen)))
    (should (equal "New" (alist-get 'displayName seen)))
    (should (equal "/tmp" (alist-get 'cwd seen)))))

(ert-deftest termini-session-view-binding-keeps-the-origin-chat-session ()
  "Binding from a list targets the chat session that opened the view."
  (let ((client (chat-termini-view-test--client)) bound-id bound-session
        (origin (list :origin t)))
    (cl-letf (((symbol-function 'chat-termini-session-list)
               (lambda (&rest _args)
                 (list (chat-termini-view-test--session))))
              ((symbol-function 'tabulated-list-get-id)
               (lambda () "rs-1"))
              ((symbol-function 'termini-bind-session)
               (lambda (id session)
                 (setq bound-id id bound-session session))))
      (with-temp-buffer
        (termini-session-view-mode)
        (setq termini-view-client client
              termini-session-view-local-session origin)
        (termini-session-view-refresh)
        (termini-session-view-bind)))
    (should (equal "rs-1" bound-id))
    (should (eq origin bound-session))))

(ert-deftest termini-job-view-refreshes-through-public-operation ()
  "Job rows remain scoped to one authoritative RuntimeSession."
  (let ((client (chat-termini-view-test--client)) seen)
    (cl-letf (((symbol-function 'chat-termini-job-list)
               (lambda (_client session-id &optional _params)
                 (setq seen session-id)
                 (list (chat-termini-view-test--job)))))
      (with-temp-buffer
        (termini-job-view-mode)
        (setq termini-view-client client
              termini-job-view-runtime-session-id "rs-1")
        (termini-job-view-refresh)
        (should (equal "rs-1" seen))
        (should (equal "job-1" (caar tabulated-list-entries)))
        (should (chat-termini-job-p
                 (gethash "job-1" termini-job-view-items)))))))

(ert-deftest termini-job-cancel-refuses-terminal-projections ()
  "Terminal jobs never expose a locally invented cancellation state."
  (let ((client (chat-termini-view-test--client)))
    (should-error
     (termini-job-cancel client (chat-termini-view-test--job 'succeeded))
     :type 'user-error)))

(ert-deftest termini-job-cancel-refreshes-after-a-conflict ()
  "A cancellation race re-reads the authoritative job projection."
  (let ((client (chat-termini-view-test--client)) refreshed)
    (cl-letf (((symbol-function 'chat-termini-job-cancel)
               (lambda (&rest _args)
                 (signal 'chat-termini-rpc-error
                         '("already terminal" -32009 "conflict"))))
              ((symbol-function 'chat-termini-job-list)
               (lambda (_client session-id &optional _params)
                 (setq refreshed session-id))))
      (should-error
       (termini-job-cancel client (chat-termini-view-test--job))
       :type 'chat-termini-rpc-error))
    (should (equal "rs-1" refreshed))))

(ert-deftest termini-job-tail-follow-is-explicit-and-scoped ()
  "Following a job asks the bridge for that exact job and session."
  (let ((client (chat-termini-view-test--client)) seen)
    (cl-letf (((symbol-function 'chat-termini-job-tail)
               (lambda (_client session-id job-id params)
                 (setq seen (list session-id job-id params))
                 (make-chat-termini-tail
                  :job-id job-id :runtime-session-id session-id
                  :text "tail" :truncated nil :status 'running))))
      (let ((tail (termini-job-tail client
                                    (chat-termini-view-test--job) t)))
        (should (equal "tail" (chat-termini-tail-text tail)))))
    (should (equal '("rs-1" "job-1") (seq-take seen 2)))
    (should (eq t (alist-get 'follow (nth 2 seen))))))

(ert-deftest termini-job-follow-rereads-tail-on-matching-notification ()
  "Follow notifications trigger a public tail refresh, not payload rendering."
  (let ((client (chat-termini-view-test--client)) observer (refreshes 0))
    (cl-letf (((symbol-function 'termini-job-detail-refresh)
               (lambda (&optional _follow) (setq refreshes (1+ refreshes))))
              ((symbol-function 'chat-termini-add-observer)
               (lambda (_client callback) (setq observer callback)))
              ((symbol-function 'run-at-time)
               (lambda (_time _repeat callback &rest args)
                 (apply callback args))))
      (with-temp-buffer
        (termini-job-detail-mode)
        (setq termini-view-client client
              termini-job-detail-job (chat-termini-view-test--job))
        (termini-job-detail-follow)
        (funcall observer "job/log_delta"
                 '((runtimeSessionId . "other") (jobId . "job-1")))
        (funcall observer "job/log_delta"
                 '((runtimeSessionId . "rs-1") (jobId . "job-1")))
        (should (= 2 refreshes))))))

(ert-deftest termini-capability-summary-is-bounded-and-structural ()
  "Capability inspection omits transient stderr and process handles."
  (let* ((client (chat-termini-view-test--client))
         (summary (termini-capability-summary client)))
    (should (equal "2026-07-08" (alist-get 'protocolVersion summary)))
    (should (equal 'ready (alist-get 'status summary)))
    (should-not (assq 'stderr summary))
    (should-not (assq 'process summary))))

(ert-deftest termini-entry-point-loads-only-when-explicit ()
  "The optional root entry point provides its own feature."
  (let ((entry (expand-file-name "termini.el" chat-test-root-dir)))
    (load entry nil t)
    (should (featurep 'termini))
    (should (fboundp 'termini-connect))
    (should (fboundp 'termini-session-view-open))))

(provide 'test-chat-termini-view)
;;; test-chat-termini-view.el ends here
