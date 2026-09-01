;;; chat-work-shelf.el --- Input-adjacent work projections -*- lexical-binding: t; -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;;; Commentary:

;; Providers expose bounded typed work projections.  They never mutate a chat
;; buffer.  chat-ui owns disclosure state, prompt controls and region replacement.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'chat-changed-files)
(require 'chat-goal)
(require 'chat-plan-mode)
(require 'chat-work-plan)
(require 'chat-repl)

(defcustom chat-work-shelf-summary-width 120
  "Maximum display width of one work-shelf summary."
  :type 'integer
  :group 'chat)

(defcustom chat-work-shelf-detail-width 160
  "Maximum display width of one work-shelf detail line."
  :type 'integer
  :group 'chat)

(defcustom chat-work-shelf-detail-limit 20
  "Maximum detail rows returned by one work-shelf provider."
  :type 'integer
  :group 'chat)

(cl-defstruct
    (chat-work-shelf-provider
     (:constructor chat-work-shelf-provider-create))
  "One typed source for an input work-shelf section."
  id priority availability-fn project-fn summary-fn details-fn event-types)

(cl-defstruct
    (chat-work-shelf-section
     (:constructor chat-work-shelf-section-create))
  "One bounded provider projection ready for UI rendering."
  id priority summary detail-lines event-types projection)

(defvar chat-work-shelf-providers nil
  "Registered work-shelf providers in no significant storage order.")

(defun chat-work-shelf-register-provider (provider)
  "Register PROVIDER, replacing any provider with the same stable ID."
  (unless (and (chat-work-shelf-provider-p provider)
               (symbolp (chat-work-shelf-provider-id provider))
               (integerp (chat-work-shelf-provider-priority provider))
               (or (null (chat-work-shelf-provider-availability-fn provider))
                   (functionp
                    (chat-work-shelf-provider-availability-fn provider)))
               (functionp (chat-work-shelf-provider-project-fn provider))
               (functionp (chat-work-shelf-provider-summary-fn provider))
               (functionp (chat-work-shelf-provider-details-fn provider)))
    (error "Invalid work-shelf provider: %S" provider))
  (setq chat-work-shelf-providers
        (cons provider
              (seq-remove
               (lambda (existing)
                 (eq (chat-work-shelf-provider-id existing)
                     (chat-work-shelf-provider-id provider)))
               chat-work-shelf-providers)))
  provider)

(defun chat-work-shelf--truncate (text width)
  "Return TEXT constrained to display WIDTH."
  (truncate-string-to-width (or text "") (max 1 width) nil nil t))

(defun chat-work-shelf--provider-section (provider session)
  "Return PROVIDER's bounded section for SESSION, or nil."
  (when (or (null (chat-work-shelf-provider-availability-fn provider))
            (funcall (chat-work-shelf-provider-availability-fn provider)
                     session))
    (when-let ((projection
                (funcall (chat-work-shelf-provider-project-fn provider)
                         session)))
      (let* ((summary
              (chat-work-shelf--truncate
               (funcall (chat-work-shelf-provider-summary-fn provider)
                        projection)
               chat-work-shelf-summary-width))
             (all-details
              (mapcar (lambda (line)
                        (chat-work-shelf--truncate
                         line chat-work-shelf-detail-width))
                      (funcall
                       (chat-work-shelf-provider-details-fn provider)
                       projection)))
             (shown (seq-take all-details chat-work-shelf-detail-limit))
             (omitted (- (length all-details) (length shown))))
        (unless (and (stringp summary) (not (string-empty-p summary)))
          (error "Work-shelf provider %s returned an empty summary"
                 (chat-work-shelf-provider-id provider)))
        (chat-work-shelf-section-create
         :id (chat-work-shelf-provider-id provider)
         :priority (chat-work-shelf-provider-priority provider)
         :summary summary
         :detail-lines
         (if (> omitted 0)
             (append shown (list (format "... %d more" omitted)))
           shown)
         :event-types (chat-work-shelf-provider-event-types provider)
         :projection projection)))))

(defun chat-work-shelf-project (session)
  "Return nonempty provider sections for SESSION in canonical order."
  (delq nil
        (mapcar
         (lambda (provider)
           (chat-work-shelf--provider-section provider session))
         (sort (copy-sequence chat-work-shelf-providers)
               (lambda (left right)
                 (let ((left-priority
                        (chat-work-shelf-provider-priority left))
                       (right-priority
                        (chat-work-shelf-provider-priority right)))
                   (if (= left-priority right-priority)
                       (string< (symbol-name
                                 (chat-work-shelf-provider-id left))
                                (symbol-name
                                 (chat-work-shelf-provider-id right)))
                     (< left-priority right-priority))))))))

(defun chat-work-shelf-event-relevant-p (event)
  "Return non-nil when EVENT can invalidate a registered shelf provider."
  (and (chat-work-shelf-provider-ids-for-event event) t))

(defun chat-work-shelf-provider-ids-for-event (event)
  "Return provider IDs invalidated by EVENT in canonical order."
  (mapcar
   #'chat-work-shelf-provider-id
   (seq-filter
    (lambda (provider)
      (memq (chat-event-type event)
            (chat-work-shelf-provider-event-types provider)))
    (sort (copy-sequence chat-work-shelf-providers)
          (lambda (left right)
            (< (chat-work-shelf-provider-priority left)
               (chat-work-shelf-provider-priority right)))))))

(defun chat-work-shelf--status-label (status)
  "Return a fixed-width label for TODO item STATUS."
  (pcase status
    ('completed "[x]")
    ('in-progress "[>]")
    ('blocked "[!]")
    ('skipped "[-]")
    (_ "[ ]")))

(defun chat-work-shelf--status-face (status)
  "Return a face for TODO item STATUS."
  (pcase status
    ('completed 'success)
    ('in-progress 'font-lock-keyword-face)
    ('blocked 'warning)
    ((or 'skipped 'pending) 'shadow)
    (_ 'default)))

(defun chat-work-shelf--todo-project (session)
  "Return SESSION's active TODO projection."
  (when-let ((projection (chat-work-plan-ui-projection session)))
    (when (memq (plist-get projection :status) '(active blocked))
      projection)))

(defun chat-work-shelf--todo-summary (projection)
  "Return one-line TODO summary for PROJECTION."
  (let* ((items (plist-get projection :items))
         (completed
          (seq-count
           (lambda (item)
             (eq (chat-work-plan-item-status item) 'completed))
           items))
         (current (plist-get projection :current-item)))
    (propertize
     (concat (format "TODO %d/%d" completed (length items))
             (when current
               (format " · %s" (chat-work-plan-item-title current)))
             (when (eq (plist-get projection :status) 'blocked)
               " · blocked"))
     'face (if (eq (plist-get projection :status) 'blocked)
               'warning 'font-lock-keyword-face))))

(defun chat-work-shelf--todo-details (projection)
  "Return bounded-ready TODO detail rows for PROJECTION."
  (mapcar
   (lambda (item)
     (let ((status (chat-work-plan-item-status item)))
       (concat
        (propertize (chat-work-shelf--status-label status)
                    'face (chat-work-shelf--status-face status))
        " "
        (propertize (chat-work-plan-item-title item)
                    'face (chat-work-shelf--status-face status))
        (if (and (eq status 'blocked)
                 (chat-work-plan-item-blocker-reason item))
            (propertize
             (format " · %s" (chat-work-plan-item-blocker-reason item))
             'face 'warning)
          ""))))
   (plist-get projection :items)))

(defun chat-work-shelf--changed-files-summary (projection)
  "Return changed-file summary for PROJECTION."
  (propertize
   (format "Changed files · %d" (plist-get projection :count))
   'face 'font-lock-keyword-face))

(defun chat-work-shelf--changed-operation-label (operation)
  "Return compact label for changed-file OPERATION."
  (pcase operation
    ('added "[+]")
    ('deleted "[-]")
    ('renamed "[>]")
    (_ "[~]")))

(defun chat-work-shelf--changed-operation-face (operation)
  "Return face for changed-file OPERATION."
  (pcase operation
    ('added 'success)
    ('deleted 'error)
    ('renamed 'font-lock-keyword-face)
    (_ 'warning)))

(defun chat-work-shelf--changed-files-details (projection)
  "Return changed-file rows for PROJECTION."
  (let ((lines
         (mapcar
          (lambda (entry)
            (let ((operation (chat-changed-file-entry-operation entry)))
              (concat
               (propertize (chat-work-shelf--changed-operation-label operation)
                           'face
                           (chat-work-shelf--changed-operation-face operation))
               " "
               (if (and (eq operation 'renamed)
                        (chat-changed-file-entry-rename-history entry))
                   (format "%s -> %s"
                           (car (last
                                 (chat-changed-file-entry-rename-history entry)))
                           (chat-changed-file-entry-path entry))
                 (chat-changed-file-entry-path entry)))))
          (plist-get projection :entries))))
    (if (> (or (plist-get projection :omitted) 0) 0)
        (append lines
                (list (format "... %d more"
                              (plist-get projection :omitted))))
      lines)))

(defun chat-work-shelf--goal-project (session)
  "Return SESSION's selected nonterminal Goal projection."
  (when-let ((projection (chat-goal-ui-projection session)))
    (when (memq (plist-get projection :status) '(active paused blocked))
      projection)))

(defun chat-work-shelf--goal-summary (projection)
  "Return Goal summary for PROJECTION."
  (let ((status (plist-get projection :status)))
    (propertize
     (format "Goal [%s] %d/%d · %s%s"
             status (plist-get projection :satisfied)
             (plist-get projection :total)
             (plist-get projection :objective)
             (if (plist-get projection :needs-attention)
                 " · needs attention" ""))
     'face (pcase status
             ('blocked 'warning)
             ('paused 'shadow)
             (_ 'font-lock-keyword-face)))))

(defun chat-work-shelf--goal-details (projection)
  "Return Goal detail rows for PROJECTION."
  (delq
   nil
   (append
    (when-let ((stopping (plist-get projection :stopping-condition)))
      (list (concat (propertize "Stop: " 'face 'shadow) stopping)))
    (when-let ((checkpoint (plist-get projection :checkpoint)))
      (list (concat (propertize "Now: " 'face 'shadow) checkpoint)))
    (when-let ((attention (plist-get projection :needs-attention)))
      (list (concat (propertize "[!] " 'face 'warning) attention)))
    (mapcar (lambda (criterion)
              (concat (propertize "[ ] " 'face 'shadow) criterion))
            (plist-get projection :remaining))
    (when-let ((reason (plist-get projection :blocker-reason)))
      (list (concat (propertize "[!] " 'face 'warning) reason)))
    (when-let ((condition (plist-get projection :unblock-condition)))
      (list (concat (propertize "Resume when: " 'face 'shadow)
                    condition))))))

(defun chat-work-shelf--plan-project (session)
  "Return SESSION's active Plan Mode projection."
  (when-let ((projection (chat-plan-mode-ui-projection session)))
    (when (plist-get projection :enabled) projection)))

(defun chat-work-shelf--plan-summary (projection)
  "Return Plan Mode summary for PROJECTION."
  (let ((status (plist-get projection :status)))
    (propertize
     (format "Plan [%s] · revision %d"
             status (plist-get projection :revision))
     'face (if (eq status 'ready) 'warning 'font-lock-keyword-face))))

(defun chat-work-shelf--plan-details (projection)
  "Return Plan Mode detail rows for PROJECTION."
  (delq nil
        (list
         (propertize "read-only" 'face 'shadow)
         (when-let ((plan-id (plist-get projection :plan-id)))
           (format "Plan ID: %s" plan-id))
         (when-let ((plan-revision (plist-get projection :plan-revision)))
           (format "Plan revision: %s" plan-revision))
         (when-let ((feedback (plist-get projection :feedback)))
           (concat (propertize "Feedback: " 'face 'shadow) feedback)))))

(defun chat-work-shelf--repl-summary (projection)
  "Return one-line REPL summary for PROJECTION."
  (let ((status (plist-get projection :status)))
    (propertize
     (format "REPL %s #%d [%s]"
             (plist-get projection :adapter)
             (plist-get projection :generation)
             status)
     'face (pcase status
             ((or 'failed 'interrupted) 'warning)
             ('busy 'font-lock-keyword-face)
             (_ 'success)))))

(defun chat-work-shelf--repl-details (projection)
  "Return bounded REPL detail rows for PROJECTION."
  (append
   (list (format "Directory: %s" (plist-get projection :directory)))
   (when-let ((active (plist-get projection :active-transaction)))
     (list (format "Running: %s" active)))
   (mapcar
    (lambda (transaction)
      (let ((output
             (replace-regexp-in-string
              "[[:space:]\n\r]+" " "
              (string-trim
               (or (chat-repl-transaction-output transaction) "")))))
        (format "[%s] %s%s"
                (chat-repl-transaction-status transaction)
                (chat-repl-transaction-id transaction)
                (if (string-empty-p output)
                    ""
                  (format " - %s%s"
                          (truncate-string-to-width output 80 nil nil t)
                          (if (chat-repl-transaction-output-truncated-p
                               transaction)
                              " [truncated]"
                            ""))))))
    (plist-get projection :transactions))))

(defun chat-work-shelf-install-default-providers ()
  "Install the canonical initial work-shelf providers."
  (chat-work-shelf-register-provider
   (chat-work-shelf-provider-create
    :id 'todo :priority 10
    :project-fn #'chat-work-shelf--todo-project
    :summary-fn #'chat-work-shelf--todo-summary
    :details-fn #'chat-work-shelf--todo-details
    :event-types
    '(plan-created plan-updated plan-skipped plan-item-started
      plan-item-completed plan-item-blocked plan-item-skipped plan-resumed
      plan-cancelled plan-completed plan-skip-consumed)))
  (chat-work-shelf-register-provider
   (chat-work-shelf-provider-create
    :id 'changed-files :priority 20
    :project-fn #'chat-changed-files-ui-projection
    :summary-fn #'chat-work-shelf--changed-files-summary
    :details-fn #'chat-work-shelf--changed-files-details
    :event-types '(changed-files-updated changed-files-rolled-back)))
  (chat-work-shelf-register-provider
   (chat-work-shelf-provider-create
    :id 'goal :priority 30
    :project-fn #'chat-work-shelf--goal-project
    :summary-fn #'chat-work-shelf--goal-summary
    :details-fn #'chat-work-shelf--goal-details
    :event-types
    '(goal-created goal-selected goal-progressed goal-paused goal-resumed
      goal-blocked goal-unblocked goal-completed goal-cancelled goal-cleared
      goal-conflicted goal-completion-refused
      goal-continuation-budget-exhausted)))
  (chat-work-shelf-register-provider
   (chat-work-shelf-provider-create
    :id 'plan :priority 40
    :project-fn #'chat-work-shelf--plan-project
    :summary-fn #'chat-work-shelf--plan-summary
    :details-fn #'chat-work-shelf--plan-details
    :event-types
    '(plan-mode-entered plan-mode-submitted plan-mode-approved
      plan-mode-rejected plan-mode-exited plan-mode-refused
      plan-mode-conflicted)))
  (chat-work-shelf-register-provider
   (chat-work-shelf-provider-create
    :id 'repl :priority 50
    :project-fn #'chat-repl-ui-projection
    :summary-fn #'chat-work-shelf--repl-summary
    :details-fn #'chat-work-shelf--repl-details
    :event-types
    '(repl-created repl-started repl-eval-queued repl-eval-started repl-output
      repl-eval-completed repl-eval-failed repl-eval-interrupted repl-reset
      repl-process-ended repl-closed))))

(chat-work-shelf-install-default-providers)

(provide 'chat-work-shelf)
;;; chat-work-shelf.el ends here
