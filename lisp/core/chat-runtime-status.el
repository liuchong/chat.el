;;; chat-runtime-status.el --- Coding runtime status projection -*- lexical-binding: t; -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;;; Commentary:

;; Pure projections for the user-visible coding phase and actionable failures.
;; Events, tasks, verification results, and executions remain authoritative.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defconst chat-runtime-status-phases
  '(planning understanding editing verifying repairing reviewing)
  "Coding phases shown by the unified chat surface.")

(defconst chat-runtime-status-error-kinds
  '(unavailable blocked stale failed timeout cancelled)
  "Closed set of actionable runtime error kinds.")

(cl-defstruct (chat-runtime-status
               (:constructor chat-runtime-status-create))
  phase kind summary action source)

(defun chat-runtime-status--value (data key)
  "Read KEY from plist or alist DATA."
  (cond
   ((null data) nil)
   ((and (listp data) (keywordp (car data))) (plist-get data key))
   ((listp data)
    (or (alist-get (intern (substring (symbol-name key) 1)) data)
        (alist-get key data)))
   (t nil)))

(defun chat-runtime-status-phase-label (phase)
  "Return a concise display label for PHASE."
  (pcase phase
    ('planning "planning")
    ('understanding "understanding")
    ('editing "editing")
    ('verifying "verifying")
    ('repairing "repairing")
    ('reviewing "reviewing")
    (_ nil)))

(defun chat-runtime-status-phase-for-tool (event)
  "Return the coding phase projected from tool EVENT."
  (let ((tool (downcase (format "%s" (or (plist-get event :tool) "")))))
    (cond
     ((string-match-p
       "\\(?:write\\|edit\\|patch\\|replace\\|create\\|delete\\|move\\|rename\\|apply\\)"
       tool)
      'editing)
     ((string-match-p
       "\\(?:verify\\|test\\|build\\|lint\\|format\\|check\\|diagnostic\\)"
       tool)
      'verifying)
     ((string-match-p "\\(?:review\\|diff\\)" tool) 'reviewing)
     ((string-match-p "\\(?:plan\\|todo\\)" tool) 'planning)
     ((string-match-p
       "\\(?:read\\|search\\|find\\|list\\|map\\|symbol\\|reference\\|definition\\|context\\)"
       tool)
      'understanding)
     (t nil))))

(defun chat-runtime-status-phase-for-event (event-type &optional payload)
  "Return the user-visible phase for EVENT-TYPE and PAYLOAD.

Return nil for events that do not change the phase and `idle' for events
that terminate visible work."
  (pcase event-type
    ((or 'plan-created 'plan-updated 'plan-item-started 'plan-resumed)
     'planning)
    ((or 'instruction-graph-observed 'context-bundle-built
         'fragment-selected 'fragment-omitted 'code-intel-query-started
         'code-intel-query-completed 'code-intel-query-failed
         'repo-map-updated 'file-observed 'stream-chunk 'stream-reasoning
         'model-retry)
     'understanding)
    ((or 'file-version-refused 'workspace-created 'workspace-reconciled
         'workspace-merge-started 'workspace-merge-completed
         'workspace-merge-conflicted)
     'editing)
    ((or 'verification-planned 'verification-step-started
         'verification-step-completed 'verification-completed)
     'verifying)
    ((or 'repair-started 'repair-stopped) 'repairing)
    ((or 'review-started 'review-finding 'review-completed) 'reviewing)
    ((or 'turn-ended 'turn-failed 'session-ended 'agent-end) 'idle)
    ('tool-event
     (chat-runtime-status-phase-for-tool
      (or (chat-runtime-status--value payload :event) payload)))
    (_ nil)))

(defun chat-runtime-status-diagnostic (domain status &optional reason)
  "Return an actionable diagnostic for DOMAIN, STATUS, and REASON."
  (let* ((domain (if (symbolp domain) domain (intern (format "%s" domain))))
         (status (if (symbolp status) status (intern (format "%s" status))))
         (kind
          (pcase status
            ((or 'unavailable 'not-run) 'unavailable)
            ('blocked 'blocked)
            ((or 'stale 'stale-file 'version-refused) 'stale)
            ((or 'timeout 'timed-out) 'timeout)
            ((or 'cancelled 'canceled) 'cancelled)
            (_ 'failed)))
         (summary
          (or (and reason
                   (truncate-string-to-width
                    (format "%s" reason) 180 nil nil t))
              (format "%s %s" domain kind)))
         (action
          (pcase (cons domain kind)
            (`(file . stale)
             "Reread the current file version, reconcile the change, then retry.")
            (`(semantic . unavailable)
             "Open the target file or build the project index, then retry the query.")
            (`(semantic . timeout)
             "Retry a narrower query; inspect backend availability if it repeats.")
            (`(verification . unavailable)
             "Configure deterministic verification steps or record the run as not-run.")
            (`(verification . blocked)
             "Resolve the reported permission or capability block before rerunning verification.")
            (`(verification . failed)
             "Inspect the failed step evidence, repair the cause, then rerun required verification.")
            (`(sandbox . unavailable)
             "Select an available tested isolation backend or explicitly choose unrestricted local execution.")
            (`(sandbox . blocked)
             "Keep the requested path or network access within the declared execution policy.")
            (`(permission . blocked)
             "Approve a narrower operation or change the request to fit the active policy.")
            (`(_ . timeout)
             "Inspect the last active step and retry with a bounded operation.")
            (`(_ . cancelled)
             "Start a new run when the cancelled work is still required.")
            (_
             "Inspect the attached evidence and retry only after the cause is resolved."))))
    (chat-runtime-status-create
     :kind kind :summary summary :action action :source domain)))

(defun chat-runtime-status-for-lifecycle-event (event-type payload)
  "Return a runtime status projection for EVENT-TYPE and PAYLOAD."
  (let ((phase (chat-runtime-status-phase-for-event event-type payload)))
    (when (memq phase chat-runtime-status-phases)
      (chat-runtime-status-create :phase phase :source event-type))))

(defun chat-runtime-status-diagnostic-for-message (message)
  "Classify MESSAGE and return an actionable runtime diagnostic."
  (let ((text (downcase (format "%s" message))))
    (cond
     ((string-match-p "\\(?:stale\\|version.refused\\|changed since\\)" text)
      (chat-runtime-status-diagnostic 'file 'stale message))
     ((string-match-p "\\(?:semantic\\|code intelligence\\|backend\\)" text)
      (chat-runtime-status-diagnostic
       'semantic
       (if (string-match-p "\\(?:timeout\\|timed out\\)" text)
           'timeout
         'unavailable)
       message))
     ((string-match-p
       "\\(?:verification\\|test failed\\|build failed\\|lint failed\\)" text)
      (chat-runtime-status-diagnostic 'verification 'failed message))
     ((string-match-p "\\(?:sandbox\\|isolation backend\\)" text)
      (chat-runtime-status-diagnostic
       'sandbox
       (if (string-match-p "\\(?:unavailable\\|not available\\|not found\\)" text)
           'unavailable
         'blocked)
       message))
     ((string-match-p "\\(?:permission\\|approval\\|denied\\|blocked\\)" text)
      (chat-runtime-status-diagnostic 'permission 'blocked message))
     ((string-match-p "\\(?:timeout\\|timed out\\)" text)
      (chat-runtime-status-diagnostic 'runtime 'timeout message))
     ((string-match-p "cancel" text)
      (chat-runtime-status-diagnostic 'runtime 'cancelled message))
     (t (chat-runtime-status-diagnostic 'runtime 'failed message)))))

(provide 'chat-runtime-status)
;;; chat-runtime-status.el ends here
