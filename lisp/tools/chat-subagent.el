;;; chat-subagent.el --- Sub-agent backends for chat.el -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: chat, agents

;; This file is not part of GNU Emacs.

;;; Commentary:

;; In-process and external subprocess-agent backends.  Parent sessions
;; receive summarized records rather than child transcripts.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'chat-session)
(require 'chat-agent)

(defcustom chat-subagent-max-depth 2
  "Maximum nested sub-agent depth."
  :type 'integer
  :group 'chat)

(defcustom chat-subagent-default-budget 10
  "Default step budget for sub-agent records."
  :type 'integer
  :group 'chat)

(cl-defstruct chat-subagent
  id
  kind
  name
  status
  depth
  budget
  parent-session
  child-session
  summary
  log-file
  process)

(defvar chat-subagent--registry (make-hash-table :test 'equal)
  "Known sub-agents keyed by id.")

(defun chat-subagent--id ()
  "Return a fresh sub-agent id."
  (chat-session-new-message-id "subagent"))

(defun chat-subagent--ensure-depth (depth)
  "Signal when DEPTH exceeds `chat-subagent-max-depth'."
  (when (> depth chat-subagent-max-depth)
    (error "Sub-agent depth limit exceeded: %s" depth)))

(defun chat-subagent-start-in-process (name messages runner
                                            &optional parent-session depth budget)
  "Start an in-process sub-agent NAME with MESSAGES and RUNNER.
RUNNER is a function called with the child session and must return a
summary string or alist.  This helper provides isolated child-session
state without dumping child transcripts into the parent."
  (let ((depth (or depth 0)))
    (chat-subagent--ensure-depth depth)
    (let* ((child-session
            (make-chat-session
             :id (chat-session-new-message-id "child-session")
             :name name
             :created-at (current-time)
             :updated-at (current-time)
             :model-id (or (and parent-session
                                (chat-session-model-id parent-session))
                           'kimi)
             :messages messages
             :parent-session-id (and parent-session
                                     (chat-session-id parent-session))))
           (subagent (make-chat-subagent
                      :id (chat-subagent--id)
                      :kind 'in-process
                      :name name
                      :status 'running
                      :depth depth
                      :budget (or budget chat-subagent-default-budget)
                      :parent-session parent-session
                      :child-session child-session)))
      (puthash (chat-subagent-id subagent) subagent chat-subagent--registry)
      (condition-case err
          (let ((summary (funcall runner child-session)))
            (setf (chat-subagent-summary subagent) summary
                  (chat-subagent-status subagent) 'completed)
            subagent)
        (error
         (setf (chat-subagent-summary subagent) (error-message-string err)
               (chat-subagent-status subagent) 'failed)
         subagent)))))

(defun chat-subagent-start-external (name command input-jsonl log-file
                                          &optional depth budget)
  "Start external subprocess-agent NAME using COMMAND.
INPUT-JSONL is written to the subprocess stdin when non-nil.  Output is
captured in LOG-FILE."
  (let ((depth (or depth 0)))
    (chat-subagent--ensure-depth depth)
    (let* ((subagent (make-chat-subagent
                      :id (chat-subagent--id)
                      :kind 'external
                      :name name
                      :status 'running
                      :depth depth
                      :budget (or budget chat-subagent-default-budget)
                      :log-file log-file))
           proc)
      (with-temp-file log-file)
      (setq proc
            (make-process
             :name (concat "chat-subagent-" (chat-subagent-id subagent))
             :buffer nil
             :command command
             :connection-type 'pipe
             :noquery t
             :filter (lambda (_proc chunk)
                       (write-region chunk nil log-file 'append 'silent))
             :sentinel (lambda (process _event)
                         (unless (process-live-p process)
                           (unless (eq (chat-subagent-status subagent)
                                       'cancelled)
                             (setf (chat-subagent-status subagent)
                                   (if (zerop (process-exit-status process))
                                       'completed
                                     'failed)))))))
      (setf (chat-subagent-process subagent) proc)
      (puthash (chat-subagent-id subagent) subagent chat-subagent--registry)
      (when input-jsonl
        (process-send-string proc input-jsonl))
      subagent)))

(defun chat-subagent-cancel (id)
  "Cancel sub-agent ID."
  (let ((subagent (gethash id chat-subagent--registry)))
    (unless subagent
      (error "Sub-agent not found: %s" id))
    (when-let ((proc (chat-subagent-process subagent)))
      (when (process-live-p proc)
        (delete-process proc)))
    (setf (chat-subagent-status subagent) 'cancelled)
    subagent))

(defun chat-subagent-describe (id)
  "Return a parent-safe summary for sub-agent ID."
  (let ((subagent (gethash id chat-subagent--registry)))
    (unless subagent
      (error "Sub-agent not found: %s" id))
    `((id . ,(chat-subagent-id subagent))
      (name . ,(chat-subagent-name subagent))
      (kind . ,(symbol-name (chat-subagent-kind subagent)))
      (status . ,(symbol-name (chat-subagent-status subagent)))
      (summary . ,(chat-subagent-summary subagent))
      (logFile . ,(chat-subagent-log-file subagent)))))

(defun chat-subagent-external-output (id)
  "Return captured external sub-agent output for ID."
  (let ((subagent (gethash id chat-subagent--registry)))
    (unless subagent
      (error "Sub-agent not found: %s" id))
    (if (and (chat-subagent-log-file subagent)
             (file-exists-p (chat-subagent-log-file subagent)))
        (with-temp-buffer
          (insert-file-contents (chat-subagent-log-file subagent))
          (buffer-string))
      "")))

(provide 'chat-subagent)
;;; chat-subagent.el ends here
