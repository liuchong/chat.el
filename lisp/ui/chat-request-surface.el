;;; chat-request-surface.el --- Shared request UI helpers -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;; Author: chat.el contributors
;; Keywords: chat, ui

;;; Commentary:

;; Shared helpers for the live request surface.

;;; Code:

(require 'chat-approval)
(require 'chat-files)
(require 'chat-request-diagnostics)
(require 'chat-request-panel)
(require 'subr-x)

(defun chat-request-surface-tool-targets (tool-events)
  "Return canonical file-target data extracted from TOOL-EVENTS."
  (let (all-paths latest-single-target)
    (dolist (event tool-events)
      (when (eq (plist-get event :type) 'tool-call)
        (let* ((tool-id (intern (plist-get event :tool)))
               (arguments (plist-get event :arguments))
               (paths (and arguments
                           (condition-case nil
                               (chat-files--tool-target-paths tool-id arguments)
                             (error nil)))))
          (when paths
            (setq all-paths (append all-paths paths))
            (when (= (length paths) 1)
              (setq latest-single-target (car paths)))))))
    (when all-paths
      (list :paths (delete-dups all-paths)
            :latest-single-target latest-single-target))))

(defun chat-request-surface-live-narrative-line (detail)
  "Return a transient live narrative line for DETAIL."
  (when (and detail (not (string-empty-p detail)))
    (propertize (format "[Live] %s" detail) 'face 'shadow)))

(defun chat-request-surface-update-panel-if-visible (source-buffer request-id tool-events)
  "Refresh the request panel for SOURCE-BUFFER when it is visible or auto shown."
  (when (and request-id
             (or chat-request-panel-auto-show
                 (get-buffer-window
                  (chat-request-panel--buffer-name source-buffer) t)))
    (chat-request-panel-update source-buffer request-id tool-events)))

(defun chat-request-surface-buffer-observer (buffer handler)
  "Return an observer that forwards diagnostics updates in BUFFER to HANDLER."
  (lambda (id trace event)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (funcall handler id trace event)))))

(defun chat-request-surface-start-refresh-timer
    (buffer request-active-p refresh-fn clear-fn &optional interval)
  "Start a live refresh timer for BUFFER.
REQUEST-ACTIVE-P decides whether the timer should keep running.
REFRESH-FN updates the surfaces.
CLEAR-FN tears down the caller-owned timer state.
INTERVAL defaults to one second."
  (run-at-time
   (or interval 1)
   (or interval 1)
   (lambda ()
     (when (buffer-live-p buffer)
       (with-current-buffer buffer
         (if (funcall request-active-p)
             (funcall refresh-fn)
           (funcall clear-fn)))))))

(defun chat-request-surface-approval-hint (tool-events last-signature)
  "Return approval hint metadata for TOOL-EVENTS.
Only return a value when it differs from LAST-SIGNATURE."
  (when-let* ((pending (seq-find
                        (lambda (event)
                          (eq (plist-get event :type) 'approval-pending))
                        tool-events))
              (tool (plist-get pending :tool))
              (actions (plist-get pending :actions)))
    (let ((signature (list tool actions (plist-get pending :command))))
      (unless (equal signature last-signature)
        (list :signature signature
              :text (chat-approval-pending-message tool actions))))))

(provide 'chat-request-surface)
;;; chat-request-surface.el ends here
