;;; chat-termini-view.el --- Native views for Termini -*- lexical-binding: t; -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: tools, processes

;;; Commentary:

;; Optional Emacs-native projections over the Termini App Server bridge.
;; Remote RuntimeSessions and jobs remain authoritative in Termini.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)
(require 'chat-termini-bridge)

(defconst termini--terminal-job-statuses
  '(succeeded failed timed_out cancelled interrupted rejected)
  "Authoritative terminal job states in the negotiated protocol.")

(defvar termini--operation-number 0
  "Last local numeric operation identity.")

(defvar-local termini-view-client nil)
(defvar-local termini-session-view-items nil)
(defvar-local termini-session-view-local-session nil)
(defvar-local termini-job-view-items nil)
(defvar-local termini-job-view-runtime-session-id nil)
(defvar-local termini-job-detail-job nil)
(defvar-local termini-job-detail-observer nil)

(defun termini--client (&optional client)
  "Return explicit CLIENT or the ready default client."
  (let ((client (or client termini-view-client chat-termini-default-client)))
    (unless client (user-error "Termini is not connected"))
    client))

(defun termini--next-operation-number ()
  "Return one process-local numeric operation identity."
  (setq termini--operation-number
        (max (1+ termini--operation-number)
             (truncate (* 1000 (float-time))))))

(defun termini--next-operation-id (prefix)
  "Return one caller identity beginning with PREFIX."
  (format "%s-%d" prefix (termini--next-operation-number)))

(defun termini--display-time (value)
  "Return a compact display string for timestamp VALUE."
  (cond
   ((numberp value)
    (format-time-string "%Y-%m-%d %H:%M"
                        (seconds-to-time (/ value 1000.0))))
   ((and (stringp value) (not (string-empty-p value))) value)
   (t "-")))

(defun termini--status-face (status)
  "Return a face for authoritative STATUS."
  (pcase status
    ((or 'accepted 'running) 'font-lock-keyword-face)
    ('succeeded 'success)
    ((or 'failed 'timed_out 'rejected) 'error)
    ((or 'cancelled 'interrupted) 'shadow)
    (_ 'default)))

(defun termini-capability-summary (&optional client)
  "Return bounded negotiated capability data for CLIENT."
  (let ((client (termini--client client)))
    `((clientId . ,(chat-termini-client-id client))
      (status . ,(chat-termini-client-status client))
      (generation . ,(chat-termini-client-generation client))
      (protocolVersion . ,(chat-termini-client-protocol-version client))
      (methods . ,(sort (copy-sequence
                         (chat-termini-client-methods client))
                        #'string<))
      (events . ,(sort (copy-sequence
                        (chat-termini-client-events client))
                       #'string<))
      (lastError . ,(chat-termini-client-last-error client)))))

;;;###autoload
(defun termini-connect (&optional command)
  "Connect the default Termini client using optional argv COMMAND."
  (interactive)
  (when (and chat-termini-default-client
             (chat-termini--process-live-p chat-termini-default-client))
    (user-error "Termini is already connected"))
  (setq chat-termini-default-client
        (chat-termini-client-create
         :id "default" :command (or command chat-termini-command)))
  (chat-termini-start chat-termini-default-client)
  (message "Termini connected with protocol %s"
           (chat-termini-client-protocol-version
            chat-termini-default-client))
  chat-termini-default-client)

;;;###autoload
(defun termini-disconnect ()
  "Disconnect the default Termini client."
  (interactive)
  (chat-termini-disconnect chat-termini-default-client)
  (message "Termini disconnected"))

;;;###autoload
(defun termini-reconnect ()
  "Reconnect the default Termini client without replaying requests."
  (interactive)
  (setq chat-termini-default-client
        (chat-termini-reconnect (termini--client)))
  (message "Termini reconnected")
  chat-termini-default-client)

;;;###autoload
(defun termini-show-capabilities (&optional client)
  "Display negotiated capabilities for CLIENT."
  (interactive)
  (let ((buffer (get-buffer-create "*Termini capabilities*")))
    (with-current-buffer buffer
      (special-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (pp-to-string (termini-capability-summary client)))
        (goto-char (point-min))))
    (pop-to-buffer buffer)))

(defun termini-session-view--row (session)
  "Return one tabulated row for SESSION."
  (list
   (chat-termini-session-id session)
   (vector
    (or (chat-termini-session-display-name session) "")
    (chat-termini-session-id session)
    (or (chat-termini-session-project-id session) "-")
    (or (chat-termini-session-cwd session) "-")
    (number-to-string (or (chat-termini-session-active-job-count session) 0))
    (termini--display-time (chat-termini-session-last-activity-at session)))))

(defun termini-session-view-refresh ()
  "Refresh RuntimeSessions from the authoritative App Server."
  (interactive)
  (let* ((client (termini--client))
         (sessions (chat-termini-session-list client)))
    (setq termini-session-view-items (make-hash-table :test 'equal))
    (dolist (session sessions)
      (puthash (chat-termini-session-id session) session
               termini-session-view-items))
    (setq tabulated-list-entries
          (mapcar #'termini-session-view--row sessions))
    (tabulated-list-print t)))

(defun termini-session-view-session-at-point ()
  "Return the RuntimeSession at point."
  (and termini-session-view-items
       (gethash (tabulated-list-get-id) termini-session-view-items)))

(defun termini-session-create (&optional client display-name cwd)
  "Create a RuntimeSession through CLIENT with DISPLAY-NAME and CWD."
  (interactive)
  (let* ((client (termini--client client))
         (display-name (or display-name (read-string "Session name: ")))
         (cwd (or cwd (read-directory-name "Working directory: ")))
         (result
          (chat-termini-session-open
           client `((mode . "create")
                    (displayName . ,display-name)
                    (cwd . ,(expand-file-name cwd)))))
         (id (alist-get 'runtimeSessionId result)))
    (when (derived-mode-p 'termini-session-view-mode)
      (termini-session-view-refresh))
    id))

(defun termini-session-open (&optional client session bind)
  "Open SESSION through CLIENT and optionally BIND the local chat session."
  (interactive)
  (let* ((client (termini--client client))
         (session (or session (termini-session-view-session-at-point))))
    (unless session (user-error "No RuntimeSession at point"))
    (let* ((id (chat-termini-session-id session))
           (result
            (chat-termini-session-open
             client `((mode . "open_existing")
                      (runtimeSessionId . ,id)))))
      (when (or bind (and (called-interactively-p 'interactive)
                          termini-session-view-local-session
                          (y-or-n-p "Bind the current chat session? ")))
        (termini-bind-session id termini-session-view-local-session))
      result)))

(defun termini-session-view-bind ()
  "Bind the RuntimeSession at point to the current local chat session."
  (interactive)
  (let ((session (termini-session-view-session-at-point)))
    (unless session (user-error "No RuntimeSession at point"))
    (unless termini-session-view-local-session
      (user-error "The session view was not opened from a chat session"))
    (termini-bind-session (chat-termini-session-id session)
                          termini-session-view-local-session)
    (message "Bound RuntimeSession %s" (chat-termini-session-id session))))

(defun termini-session-view-show-detail ()
  "Show the bounded RuntimeSession projection at point."
  (interactive)
  (let ((session (termini-session-view-session-at-point)))
    (unless session (user-error "No RuntimeSession at point"))
    (let ((buffer (get-buffer-create "*Termini session detail*")))
      (with-current-buffer buffer
        (special-mode)
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (pp-to-string session))
          (goto-char (point-min))))
      (pop-to-buffer buffer))))

(defun termini-session-view-open-jobs ()
  "Open jobs for the RuntimeSession at point."
  (interactive)
  (let ((session (termini-session-view-session-at-point)))
    (unless session (user-error "No RuntimeSession at point"))
    (termini-job-view-open (chat-termini-session-id session)
                           (termini--client))))

(defun termini-session-view-run-command ()
  "Run a command in the RuntimeSession at point."
  (interactive)
  (let ((session (termini-session-view-session-at-point)))
    (unless session (user-error "No RuntimeSession at point"))
    (chat-termini-command-run
     (termini--client) (chat-termini-session-id session)
     (read-string "Termini command: ") (termini--next-operation-number))
    (termini-session-view-refresh)))

(define-derived-mode termini-session-view-mode tabulated-list-mode
  "Termini Sessions"
  "Major mode for browsing Termini RuntimeSessions."
  (setq tabulated-list-format
        [("Name" 24 t) ("RuntimeSession" 24 t) ("Project" 18 t)
         ("Working directory" 36 t) ("Jobs" 6 t) ("Activity" 17 t)])
  (setq tabulated-list-padding 2)
  (tabulated-list-init-header))

(define-key termini-session-view-mode-map (kbd "g")
            #'termini-session-view-refresh)
(define-key termini-session-view-mode-map (kbd "RET")
            #'termini-session-view-show-detail)
(define-key termini-session-view-mode-map (kbd "c") #'termini-session-create)
(define-key termini-session-view-mode-map (kbd "o") #'termini-session-open)
(define-key termini-session-view-mode-map (kbd "b")
            #'termini-session-view-bind)
(define-key termini-session-view-mode-map (kbd "j")
            #'termini-session-view-open-jobs)
(define-key termini-session-view-mode-map (kbd "!")
            #'termini-session-view-run-command)

;;;###autoload
(defun termini-session-view-open (&optional client)
  "Open the RuntimeSession list through CLIENT."
  (interactive)
  (let ((buffer (get-buffer-create "*Termini sessions*"))
        (local-session (and (boundp 'chat--current-session)
                            chat--current-session)))
    (with-current-buffer buffer
      (termini-session-view-mode)
      (setq termini-view-client (termini--client client)
            termini-session-view-local-session local-session)
      (termini-session-view-refresh))
    (pop-to-buffer buffer)))

(defun termini-job-view--row (job)
  "Return one tabulated row for JOB."
  (list
   (chat-termini-job-id job)
   (vector
    (chat-termini-job-id job)
    (or (chat-termini-job-tool job) "-")
    (propertize (symbol-name (chat-termini-job-status job))
                'face (termini--status-face
                       (chat-termini-job-status job)))
    (format "%s" (or (chat-termini-job-duration-ms job) "-"))
    (format "%s" (or (chat-termini-job-exit-code job) "-"))
    (or (chat-termini-job-command-preview job) ""))))

(defun termini-job-view-refresh ()
  "Refresh jobs for the current RuntimeSession."
  (interactive)
  (unless termini-job-view-runtime-session-id
    (user-error "No RuntimeSession scope"))
  (let ((jobs (chat-termini-job-list
               (termini--client) termini-job-view-runtime-session-id)))
    (setq termini-job-view-items (make-hash-table :test 'equal))
    (dolist (job jobs)
      (puthash (chat-termini-job-id job) job termini-job-view-items))
    (setq tabulated-list-entries (mapcar #'termini-job-view--row jobs))
    (tabulated-list-print t)))

(defun termini-job-view-job-at-point ()
  "Return the job at point."
  (and termini-job-view-items
       (gethash (tabulated-list-get-id) termini-job-view-items)))

(defun termini-job-tail (client job &optional follow cursor)
  "Read JOB tail through CLIENT, optionally requesting FOLLOW from CURSOR."
  (chat-termini-job-tail
   (termini--client client)
   (chat-termini-job-runtime-session-id job)
   (chat-termini-job-id job)
   (delq nil `((maxBytes . 65536) (maxLines . 200)
               (follow . ,(eq t follow))
               ,(and cursor (cons 'cursor cursor))))))

(defun termini-job-detail-refresh (&optional follow)
  "Refresh the current job tail, optionally enabling FOLLOW."
  (interactive)
  (unless termini-job-detail-job (user-error "No Termini job"))
  (let ((tail (termini-job-tail
               (termini--client) termini-job-detail-job follow)))
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (format "Job %s\nStatus: %s%s\n\n"
                      (chat-termini-tail-job-id tail)
                      (chat-termini-tail-status tail)
                      (if (chat-termini-tail-truncated tail)
                          " (truncated)" "")))
      (insert (chat-termini-tail-text tail))
      (goto-char (point-min)))
    tail))

(defun termini-job-detail-follow ()
  "Enable server-side follow for the current job."
  (interactive)
  (termini-job-detail-refresh t)
  (unless termini-job-detail-observer
    (let ((buffer (current-buffer))
          (runtime-session-id
           (chat-termini-job-runtime-session-id termini-job-detail-job))
          (job-id (chat-termini-job-id termini-job-detail-job)))
      (setq termini-job-detail-observer
            (lambda (method params)
              (when (and (equal method "job/log_delta")
                         (equal (alist-get 'runtimeSessionId params)
                                runtime-session-id)
                         (equal (alist-get 'jobId params)
                                job-id))
                (run-at-time
                 0 nil
                 (lambda ()
                   (when (buffer-live-p buffer)
                     (with-current-buffer buffer
                       (when (and (derived-mode-p
                                   'termini-job-detail-mode)
                                  (eq 'ready
                                      (chat-termini-client-status
                                       (termini--client))))
                         (termini-job-detail-refresh)))))))))
      (chat-termini-add-observer (termini--client)
                                  termini-job-detail-observer)))
  (message "Following Termini job %s"
           (chat-termini-job-id termini-job-detail-job)))

(defun termini-job-detail-stop-observer ()
  "Remove the notification observer owned by this detail buffer."
  (when (and termini-job-detail-observer termini-view-client)
    (chat-termini-remove-observer termini-view-client
                                  termini-job-detail-observer))
  (setq termini-job-detail-observer nil))

(define-derived-mode termini-job-detail-mode special-mode "Termini Job"
  "Major mode for a bounded Termini job tail."
  (add-hook 'kill-buffer-hook #'termini-job-detail-stop-observer nil t))

(define-key termini-job-detail-mode-map (kbd "g")
            #'termini-job-detail-refresh)
(define-key termini-job-detail-mode-map (kbd "f")
            #'termini-job-detail-follow)

(defun termini-job-view-show-tail (&optional follow)
  "Open the job tail at point and optionally request FOLLOW."
  (interactive)
  (let ((job (termini-job-view-job-at-point)))
    (unless job (user-error "No job at point"))
    (let ((buffer (get-buffer-create
                   (format "*Termini job %s*" (chat-termini-job-id job))))
          (client (termini--client)))
      (with-current-buffer buffer
        (termini-job-detail-mode)
        (setq termini-view-client client
              termini-job-detail-job job)
        (termini-job-detail-refresh follow))
      (pop-to-buffer buffer))))

(defun termini-job-view-follow ()
  "Open and follow the job at point."
  (interactive)
  (termini-job-view-show-tail t))

(defun termini-job-cancel (client job)
  "Cancel nonterminal JOB through CLIENT and refresh conflicts."
  (when (memq (chat-termini-job-status job) termini--terminal-job-statuses)
    (user-error "Job %s is already %s"
                (chat-termini-job-id job)
                (chat-termini-job-status job)))
  (let ((client (termini--client client)))
    (condition-case err
        (chat-termini-job-cancel
         client
         (chat-termini-job-runtime-session-id job)
         (chat-termini-job-id job)
         (termini--next-operation-id "cancel"))
      (chat-termini-rpc-error
       (when (equal "conflict" (nth 3 err))
         (if (derived-mode-p 'termini-job-view-mode)
             (termini-job-view-refresh)
           (chat-termini-job-list
            client (chat-termini-job-runtime-session-id job))))
       (signal (car err) (cdr err))))))

(defun termini-job-view-cancel ()
  "Cancel the nonterminal job at point."
  (interactive)
  (let ((job (termini-job-view-job-at-point)))
    (unless job (user-error "No job at point"))
    (when (yes-or-no-p (format "Cancel job %s? "
                               (chat-termini-job-id job)))
      (termini-job-cancel (termini--client) job)
      (termini-job-view-refresh))))

(defun termini-job-view-show-detail ()
  "Show the bounded job projection at point."
  (interactive)
  (let ((job (termini-job-view-job-at-point)))
    (unless job (user-error "No job at point"))
    (let ((buffer (get-buffer-create "*Termini job detail*")))
      (with-current-buffer buffer
        (special-mode)
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (pp-to-string job))
          (goto-char (point-min))))
      (pop-to-buffer buffer))))

(define-derived-mode termini-job-view-mode tabulated-list-mode "Termini Jobs"
  "Major mode for browsing authoritative Termini jobs."
  (setq tabulated-list-format
        [("Job" 24 t) ("Tool" 14 t) ("Status" 12 t)
         ("Duration ms" 12 t) ("Exit" 7 t) ("Command" 48 t)])
  (setq tabulated-list-padding 2)
  (tabulated-list-init-header))

(define-key termini-job-view-mode-map (kbd "g") #'termini-job-view-refresh)
(define-key termini-job-view-mode-map (kbd "RET")
            #'termini-job-view-show-detail)
(define-key termini-job-view-mode-map (kbd "t")
            #'termini-job-view-show-tail)
(define-key termini-job-view-mode-map (kbd "f") #'termini-job-view-follow)
(define-key termini-job-view-mode-map (kbd "c") #'termini-job-view-cancel)

;;;###autoload
(defun termini-job-view-open (runtime-session-id &optional client)
  "Open jobs for RUNTIME-SESSION-ID through CLIENT."
  (interactive
   (list (or (termini-bound-session-id)
             (read-string "RuntimeSession ID: "))))
  (let ((buffer (get-buffer-create
                 (format "*Termini jobs %s*" runtime-session-id))))
    (with-current-buffer buffer
      (termini-job-view-mode)
      (setq termini-view-client (termini--client client)
            termini-job-view-runtime-session-id runtime-session-id)
      (termini-job-view-refresh))
    (pop-to-buffer buffer)))

(defun termini-attachment-stage
    (runtime-session-id path &optional client file-name)
  "Stage PATH for RUNTIME-SESSION-ID through CLIENT."
  (interactive
   (list (or (termini-bound-session-id)
             (read-string "RuntimeSession ID: "))
         (read-file-name "Stage attachment: " nil nil t)))
  (chat-termini-attachment-stage
   (termini--client client) runtime-session-id
   (expand-file-name path) file-name))

(defun termini-attachment-save
    (runtime-session-id attachment-id destination &optional client)
  "Read ATTACHMENT-ID and save it to DESTINATION explicitly."
  (interactive
   (list (or (termini-bound-session-id)
             (read-string "RuntimeSession ID: "))
         (read-string "Attachment ID: ")
         (read-file-name "Save attachment: ")))
  (let* ((result (chat-termini-attachment-read
                  (termini--client client)
                  runtime-session-id attachment-id))
         (bytes (plist-get result :bytes)))
    (let ((coding-system-for-write 'no-conversion))
      (write-region bytes nil destination nil 'silent))
    destination))

(defun termini-attachment-discard
    (runtime-session-id attachment-id &optional client)
  "Discard staged ATTACHMENT-ID from RUNTIME-SESSION-ID."
  (interactive
   (list (or (termini-bound-session-id)
             (read-string "RuntimeSession ID: "))
         (read-string "Attachment ID: ")))
  (chat-termini-attachment-discard
   (termini--client client) runtime-session-id attachment-id))

(provide 'chat-termini-view)
;;; chat-termini-view.el ends here
