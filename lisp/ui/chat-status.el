;;; chat-status.el --- Shared status surface rules -*- lexical-binding: t -*-

;;; Code:

(require 'seq)

(defun chat-status-persistent-event (tool-events)
  "Return the one TOOL-EVENTS entry worth surfacing persistently."
  (seq-find
   (lambda (event)
     (eq (plist-get event :type) 'approval-pending))
   tool-events))

(defun chat-status-persistent-label (tool-events)
  "Return a persistent status label for TOOL-EVENTS."
  (when-let ((event (chat-status-persistent-event tool-events)))
    (format "Approval Pending: %s" (plist-get event :tool))))

(provide 'chat-status)
