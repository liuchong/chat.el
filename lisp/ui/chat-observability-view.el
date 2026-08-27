;;; chat-observability-view.el --- Memory, Trace and evaluation views -*- lexical-binding: t; -*-

;;; Commentary:

;; Compact native projections over the M7 public APIs.

;;; Code:

(require 'pp)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)
(require 'chat-memory)
(require 'chat-session)
(require 'chat-trace)
(require 'chat-eval)

(defun chat-observability--insert-value (label value)
  "Insert detail LABEL and VALUE."
  (insert (propertize (concat label "\n") 'face 'bold))
  (insert (if (stringp value) value (pp-to-string value)))
  (unless (bolp) (insert "\n"))
  (insert "\n"))

(defun chat-observability--timestamp (milliseconds)
  "Format MILLISECONDS for a compact local display."
  (if (numberp milliseconds)
      (format-time-string "%Y-%m-%d %H:%M:%S"
                          (seconds-to-time (/ milliseconds 1000.0)))
    ""))

(defun chat-observability--status-face (status)
  "Return an existing face suitable for STATUS."
  (pcase status
    ((or 'passed 'completed 'active) 'success)
    ((or 'failed 'rejected 'interrupted) 'error)
    ((or 'sensitive 'archived) 'warning)
    (_ 'default)))

;; Memory

(defvar-local chat-memory-view-session nil)

(defun chat-memory-view--row (item)
  "Return a tabulated row for memory ITEM."
  (let ((status (chat-memory-item-status item))
        (sensitivity (chat-memory-item-sensitivity item)))
    (list
     (chat-memory-item-id item)
     (vector
      (truncate-string-to-width
       (replace-regexp-in-string "[\n\r]+" " "
                                 (chat-memory-item-content item))
       52 nil nil t)
      (symbol-name (chat-memory-item-scope item))
      (format "%.2f" (chat-memory-item-confidence item))
      (propertize (symbol-name sensitivity)
                  'face (chat-observability--status-face sensitivity))
      (propertize (symbol-name status)
                  'face (chat-observability--status-face status))
      (format "%s:%s"
              (chat-memory-item-source-kind item)
              (chat-memory-item-source-id item))
      (chat-observability--timestamp
       (chat-memory-item-updated-at item))))))

(defun chat-memory-view-refresh ()
  "Refresh the structured memory list."
  (interactive)
  (setq tabulated-list-entries
        (mapcar #'chat-memory-view--row (chat-memory-list t)))
  (tabulated-list-print t))

(defun chat-memory-view-item-at-point ()
  "Return the memory item represented by the current row."
  (when-let* ((id (tabulated-list-get-id)))
    (chat-memory-get id)))

(define-derived-mode chat-memory-detail-mode special-mode "Chat Memory")

(defun chat-memory-view-show-detail ()
  "Open the memory item at point in a read-only detail buffer."
  (interactive)
  (let ((item (chat-memory-view-item-at-point)))
    (unless item (user-error "No memory item at point"))
    (let ((buffer (get-buffer-create
                   (format "*chat memory %s*" (chat-memory-item-id item)))))
      (with-current-buffer buffer
        (chat-memory-detail-mode)
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (propertize (chat-memory-item-content item)
                              'face '(:height 1.15 :weight bold))
                  "\n\n")
          (chat-observability--insert-value
           "Identity"
           (list :id (chat-memory-item-id item)
                 :schema (chat-memory-item-schema-version item)
                 :status (chat-memory-item-status item)))
          (chat-observability--insert-value
           "Provenance"
           (list :source-kind (chat-memory-item-source-kind item)
                 :source-id (chat-memory-item-source-id item)
                 :confidence (chat-memory-item-confidence item)))
          (chat-observability--insert-value
           "Scope and retention"
           (list :scope (chat-memory-item-scope item)
                 :scope-id (chat-memory-item-scope-id item)
                 :retention (chat-memory-item-retention item)
                 :sensitivity (chat-memory-item-sensitivity item)
                 :expires-at (chat-memory-item-expires-at item)))
          (chat-observability--insert-value
           "Metadata" (chat-memory-item-metadata item))
          (goto-char (point-min))))
      (pop-to-buffer buffer))))

(defun chat-memory-view--scope-id (scope)
  "Return a scope ID for SCOPE from the current view session."
  (pcase scope
    ('session
     (or (and chat-memory-view-session
              (chat-session-id chat-memory-view-session))
         (read-string "Session ID: ")))
    ('project
     (or (and chat-memory-view-session
              (chat-session-working-directory chat-memory-view-session))
         (read-directory-name "Project: ")))
    (_ nil)))

(defun chat-memory-view-add ()
  "Add one user-reviewed memory item."
  (interactive)
  (let* ((content (read-string "Memory: "))
         (scope (intern
                 (completing-read "Scope: "
                                  '("global" "project" "session")
                                  nil t nil nil "global")))
         (scope-id (chat-memory-view--scope-id scope))
         (confidence (read-number "Confidence (0..1): " 1.0))
         (sensitivity
          (intern (completing-read "Sensitivity: "
                                   '("normal" "sensitive")
                                   nil t nil nil "normal")))
         (source-id (read-string "Source ID: " "user:manual")))
    (chat-memory-add content :scope scope :scope-id scope-id
                     :confidence confidence :sensitivity sensitivity
                     :source-id source-id)
    (chat-memory-view-refresh)))

(defun chat-memory-view-edit ()
  "Edit the content of the memory item at point."
  (interactive)
  (let ((item (chat-memory-view-item-at-point)))
    (unless item (user-error "No memory item at point"))
    (chat-memory-update
     (chat-memory-item-id item)
     (list :content
           (read-string "Memory: " (chat-memory-item-content item))))
    (chat-memory-view-refresh)))

(defun chat-memory-view-archive ()
  "Archive the memory item at point."
  (interactive)
  (let ((item (chat-memory-view-item-at-point)))
    (unless item (user-error "No memory item at point"))
    (when (yes-or-no-p (format "Archive %s? " (chat-memory-item-id item)))
      (chat-memory-archive (chat-memory-item-id item))
      (chat-memory-view-refresh))))

(defun chat-memory-view-delete ()
  "Permanently delete the memory item at point."
  (interactive)
  (let ((item (chat-memory-view-item-at-point)))
    (unless item (user-error "No memory item at point"))
    (when (yes-or-no-p (format "Delete %s permanently? "
                               (chat-memory-item-id item)))
      (chat-memory-delete (chat-memory-item-id item))
      (chat-memory-view-refresh))))

(defun chat-memory-view-merge ()
  "Merge the item at point with another memory item."
  (interactive)
  (let ((first (chat-memory-view-item-at-point)))
    (unless first (user-error "No memory item at point"))
    (let* ((ids (delete (chat-memory-item-id first)
                        (mapcar #'chat-memory-item-id
                                (chat-memory-list t))))
           (_ (unless ids (user-error "No other memory item to merge")))
           (second (completing-read "Merge with: " ids nil t))
           (content (read-string "Merged memory: "
                                 (chat-memory-item-content first))))
      (chat-memory-merge (list (chat-memory-item-id first) second) content)
      (chat-memory-view-refresh))))

(defun chat-memory-view-toggle-automatic ()
  "Toggle automatic memory candidate capture."
  (interactive)
  (let ((enabled (chat-memory-set-automatic
                  (not (chat-memory-auto-enabled-p)))))
    (message "Automatic memory %s" (if enabled "enabled" "disabled"))))

(define-derived-mode chat-memory-view-mode tabulated-list-mode "Chat Memory"
  "Major mode for reviewing structured memory."
  (setq tabulated-list-format
        [("Memory" 52 t) ("Scope" 9 t) ("Confidence" 10 t)
         ("Sensitivity" 12 t) ("Status" 10 t) ("Source" 28 t)
         ("Updated" 19 t)])
  (setq tabulated-list-padding 2)
  (tabulated-list-init-header))

(define-key chat-memory-view-mode-map (kbd "g") #'chat-memory-view-refresh)
(define-key chat-memory-view-mode-map (kbd "RET") #'chat-memory-view-show-detail)
(define-key chat-memory-view-mode-map (kbd "a") #'chat-memory-view-add)
(define-key chat-memory-view-mode-map (kbd "e") #'chat-memory-view-edit)
(define-key chat-memory-view-mode-map (kbd "m") #'chat-memory-view-merge)
(define-key chat-memory-view-mode-map (kbd "x") #'chat-memory-view-archive)
(define-key chat-memory-view-mode-map (kbd "D") #'chat-memory-view-delete)
(define-key chat-memory-view-mode-map (kbd "A")
            #'chat-memory-view-toggle-automatic)

;;;###autoload
(defun chat-memory-view-open (&optional session)
  "Open structured memory review, scoped with optional SESSION."
  (interactive)
  (let ((buffer (get-buffer-create "*chat memory*")))
    (with-current-buffer buffer
      (chat-memory-view-mode)
      (setq chat-memory-view-session
            (or session (and (boundp 'chat--current-session)
                             chat--current-session)))
      (chat-memory-view-refresh))
    (pop-to-buffer buffer)))

;; Trace

(defvar-local chat-trace-view-trace nil)

(defun chat-trace-view--row (turn)
  "Return a tabulated row for TURN."
  (list
   (chat-trace-turn-id turn)
   (vector
    (format "%s" (chat-trace-turn-id turn))
    (propertize (symbol-name (chat-trace-turn-status turn))
                'face (chat-observability--status-face
                       (chat-trace-turn-status turn)))
    (format "%s" (or (chat-trace-turn-duration-ms turn) "-"))
    (format "%s" (or (chat-trace-turn-first-output-ms turn) "-"))
    (format "%s" (or (alist-get 'total_tokens
                                (chat-trace-turn-tokens turn)) 0))
    (format "%s" (or (alist-get 'tools (chat-trace-turn-counts turn)) 0))
    (format "%s" (or (alist-get 'approvals
                                (chat-trace-turn-counts turn)) 0))
    (format "%s" (length (chat-trace-turn-task-ids turn))))))

(defun chat-trace-view-refresh ()
  "Reconstruct and refresh the current Trace."
  (interactive)
  (unless chat-trace-view-trace (user-error "No Trace session"))
  (setq chat-trace-view-trace
        (chat-trace-reconstruct
         (chat-trace-session-id chat-trace-view-trace))
        tabulated-list-entries
        (mapcar #'chat-trace-view--row
                (chat-trace-turns chat-trace-view-trace)))
  (tabulated-list-print t))

(define-derived-mode chat-trace-detail-mode special-mode "Chat Trace")

(defun chat-trace-view-show-detail ()
  "Show the complete bounded Trace projection."
  (interactive)
  (unless chat-trace-view-trace (user-error "No Trace loaded"))
  (let ((buffer (get-buffer-create
                 (format "*chat trace %s detail*"
                         (chat-trace-session-id chat-trace-view-trace)))))
    (with-current-buffer buffer
      (chat-trace-detail-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize
                 (format "Session %s" (chat-trace-session-id
                                       chat-trace-view-trace))
                 'face '(:height 1.25 :weight bold))
                "\n\n")
        (chat-observability--insert-value
         "Summary" (chat-trace-to-json-data chat-trace-view-trace))
        (goto-char (point-min))))
    (pop-to-buffer buffer)))

(defun chat-trace-view-export ()
  "Write the current bounded Trace projection as JSON."
  (interactive)
  (unless chat-trace-view-trace (user-error "No Trace loaded"))
  (let ((file (read-file-name "Export Trace: " nil nil nil
                              (format "%s-trace.json"
                                      (chat-trace-session-id
                                       chat-trace-view-trace)))))
    (with-temp-file file
      (insert (chat-trace-export-json chat-trace-view-trace)))
    (message "Trace exported to %s" file)))

(defun chat-trace-view-compare ()
  "Compare the current Trace with another session."
  (interactive)
  (unless chat-trace-view-trace (user-error "No Trace loaded"))
  (let* ((other-id (read-string "Other session ID: "))
         (comparison
          (chat-trace-compare chat-trace-view-trace
                              (chat-trace-reconstruct other-id)))
         (buffer (get-buffer-create "*chat trace comparison*")))
    (with-current-buffer buffer
      (special-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (pp-to-string comparison))
        (goto-char (point-min))))
    (pop-to-buffer buffer)))

(define-derived-mode chat-trace-view-mode tabulated-list-mode "Chat Trace"
  "Major mode for inspecting reconstructed Turn traces."
  (setq tabulated-list-format
        [("Turn" 12 t) ("Status" 12 t) ("Duration ms" 12 t)
         ("First output" 13 t) ("Tokens" 10 t) ("Tools" 7 t)
         ("Approvals" 10 t) ("Tasks" 7 t)])
  (setq tabulated-list-padding 2)
  (tabulated-list-init-header))

(define-key chat-trace-view-mode-map (kbd "g") #'chat-trace-view-refresh)
(define-key chat-trace-view-mode-map (kbd "RET") #'chat-trace-view-show-detail)
(define-key chat-trace-view-mode-map (kbd "e") #'chat-trace-view-export)
(define-key chat-trace-view-mode-map (kbd "c") #'chat-trace-view-compare)

;;;###autoload
(defun chat-trace-view-open (&optional session-id)
  "Open a reconstructed Trace for SESSION-ID."
  (interactive)
  (let* ((current (and (boundp 'chat--current-session)
                       chat--current-session))
         (id (or session-id
                 (and current (chat-session-id current))
                 (read-string "Session ID: ")))
         (buffer (get-buffer-create (format "*chat trace %s*" id))))
    (with-current-buffer buffer
      (chat-trace-view-mode)
      (setq chat-trace-view-trace (chat-trace-reconstruct id)
            tabulated-list-entries
            (mapcar #'chat-trace-view--row
                    (chat-trace-turns chat-trace-view-trace)))
      (tabulated-list-print t))
    (pop-to-buffer buffer)))

;; Evaluations

(defun chat-eval-view--row (result)
  "Return a tabulated row for evaluation RESULT."
  (list
   (chat-eval-result-id result)
   (vector
    (chat-eval-result-scenario-id result)
    (number-to-string (chat-eval-result-scenario-revision result))
    (propertize (symbol-name (chat-eval-result-status result))
                'face (chat-observability--status-face
                       (chat-eval-result-status result)))
    (format "%d/%d"
            (seq-count #'chat-eval-check-passed
                       (chat-eval-result-checks result))
            (length (chat-eval-result-checks result)))
    (number-to-string (chat-eval-result-duration-ms result))
    (chat-eval-result-fixture-id result)
    (chat-observability--timestamp
     (chat-eval-result-started-at result)))))

(defun chat-eval-view-refresh ()
  "Refresh persisted evaluation results."
  (interactive)
  (setq tabulated-list-entries
        (mapcar #'chat-eval-view--row (chat-eval-results)))
  (tabulated-list-print t))

(defun chat-eval-view-result-at-point ()
  "Return the evaluation result represented by the current row."
  (when-let* ((id (tabulated-list-get-id)))
    (chat-eval-load-result id)))

(define-derived-mode chat-eval-detail-mode special-mode "Chat Evaluation")

(defun chat-eval-view-show-detail ()
  "Open named checks for the evaluation result at point."
  (interactive)
  (let ((result (chat-eval-view-result-at-point)))
    (unless result (user-error "No evaluation result at point"))
    (let ((buffer (get-buffer-create
                   (format "*chat evaluation %s*"
                           (chat-eval-result-id result)))))
      (with-current-buffer buffer
        (chat-eval-detail-mode)
        (let ((inhibit-read-only t))
          (erase-buffer)
          (chat-observability--insert-value
           "Result" (chat-eval-to-json-data result))
          (goto-char (point-min))))
      (pop-to-buffer buffer))))

(defun chat-eval-view-export ()
  "Write the selected bounded evaluation result as JSON."
  (interactive)
  (let ((result (chat-eval-view-result-at-point)))
    (unless result (user-error "No evaluation result at point"))
    (let ((file (read-file-name
                 "Export evaluation: " nil nil nil
                 (format "%s.json" (chat-eval-result-id result)))))
      (with-temp-file file
        (insert (chat-eval-export-json result)))
      (message "Evaluation exported to %s" file))))

(defun chat-eval-view-run-all ()
  "Run all deterministic offline Agent scenarios."
  (interactive)
  (let* ((results (chat-eval-run-all))
         (failed (seq-count
                  (lambda (result)
                    (eq 'failed (chat-eval-result-status result)))
                  results)))
    (chat-eval-view-refresh)
    (message "Evaluations: %d run, %d failed" (length results) failed)))

(defun chat-eval-view-run-scenario ()
  "Run one registered offline scenario."
  (interactive)
  (let* ((ids (mapcar #'chat-eval-scenario-id (chat-eval-scenarios)))
         (id (completing-read "Scenario: " ids nil t)))
    (chat-eval-run id)
    (chat-eval-view-refresh)))

(defun chat-eval-view-run-live ()
  "Run registered live scenarios after explicit confirmation."
  (interactive)
  (let ((live
         (seq-filter #'chat-eval-scenario-live-p
                     (chat-eval-scenarios t))))
    (unless live (user-error "No live evaluation scenarios are registered"))
    (when (yes-or-no-p (format "Run %d live scenarios? " (length live)))
      (mapc #'chat-eval-run live)
      (chat-eval-view-refresh))))

(defun chat-eval-view-compare ()
  "Compare the result at point with another compatible result."
  (interactive)
  (let ((left (chat-eval-view-result-at-point)))
    (unless left (user-error "No evaluation result at point"))
    (let* ((candidates
            (seq-remove
             (lambda (result)
               (equal (chat-eval-result-id result)
                      (chat-eval-result-id left)))
             (chat-eval-results (chat-eval-result-scenario-id left))))
           (id (completing-read
                "Compare with: "
                (mapcar #'chat-eval-result-id candidates) nil t))
           (comparison
            (chat-eval-compare left (chat-eval-load-result id)))
           (buffer (get-buffer-create "*chat evaluation comparison*")))
      (with-current-buffer buffer
        (special-mode)
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (pp-to-string comparison))
          (goto-char (point-min))))
      (pop-to-buffer buffer))))

(define-derived-mode chat-eval-view-mode tabulated-list-mode "Chat Evaluations"
  "Major mode for running and inspecting Agent evaluations."
  (setq tabulated-list-format
        [("Scenario" 32 t) ("Rev" 5 t) ("Status" 10 t)
         ("Checks" 9 t) ("Duration ms" 12 t) ("Fixture" 24 t)
         ("Started" 19 t)])
  (setq tabulated-list-padding 2)
  (tabulated-list-init-header))

(define-key chat-eval-view-mode-map (kbd "g") #'chat-eval-view-refresh)
(define-key chat-eval-view-mode-map (kbd "RET") #'chat-eval-view-show-detail)
(define-key chat-eval-view-mode-map (kbd "r") #'chat-eval-view-run-scenario)
(define-key chat-eval-view-mode-map (kbd "R") #'chat-eval-view-run-all)
(define-key chat-eval-view-mode-map (kbd "L") #'chat-eval-view-run-live)
(define-key chat-eval-view-mode-map (kbd "c") #'chat-eval-view-compare)
(define-key chat-eval-view-mode-map (kbd "e") #'chat-eval-view-export)

;;;###autoload
(defun chat-eval-view-open ()
  "Open persisted Agent evaluation results."
  (interactive)
  (let ((buffer (get-buffer-create "*chat evaluations*")))
    (with-current-buffer buffer
      (chat-eval-view-mode)
      (chat-eval-view-refresh))
    (pop-to-buffer buffer)))

(provide 'chat-observability-view)
;;; chat-observability-view.el ends here
