;;; chat-status.el --- Shared status surface rules -*- lexical-binding: t -*-

;;; Code:

(require 'seq)

(defun chat-status-persistent-event (tool-events)
  "Return the one TOOL-EVENTS entry worth surfacing persistently."
  (seq-find
   (lambda (event)
     (eq (plist-get event :type) 'approval-pending))
   tool-events))

(defun chat-status-guard-pending-event (tool-events)
  "Return the guard request TOOL-EVENTS is still waiting on, or nil.

Paired by position rather than by identity: a verdict event after the last
request means nothing is outstanding.  The pairing has to be here, because
under `guarded' nobody is asked anything and this indicator is the only
sign a model is being consulted -- one that stayed up for the rest of the
turn would report a decision already taken as still pending."
  (let ((pending nil))
    (dolist (event tool-events)
      (pcase (plist-get event :type)
        ('approval-guard-pending (setq pending event))
        ('approval (setq pending nil))))
    pending))

(defun chat-status-persistent-label (tool-events)
  "Return a persistent status label for TOOL-EVENTS.

A question for the user outranks a request to the guard: one is waiting on
them and the other resolves by itself."
  (if-let ((event (chat-status-persistent-event tool-events)))
      (format "Approval Pending: %s" (plist-get event :tool))
    (when-let ((event (chat-status-guard-pending-event tool-events)))
      (format "Guard Judging: %s" (plist-get event :tool)))))

(provide 'chat-status)
