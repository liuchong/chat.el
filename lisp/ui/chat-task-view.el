;;; chat-task-view.el --- Native task tree and details -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;;; Commentary:

;; A compact Emacs-native projection of durable runtime tasks.  The list is
;; intentionally bounded; payloads, checkpoints, and outcomes live in a
;; separate read-only detail buffer.

;;; Code:

(require 'cl-lib)
(require 'pp)
(require 'subr-x)
(require 'tabulated-list)
(require 'chat-session)
(require 'chat-task)
(require 'chat-work)

(defvar-local chat-task-view-session-id nil
  "Optional session id filter for the current task list.")

(defvar-local chat-task-view-detail-task-id nil
  "Task shown in the current detail buffer.")

(defun chat-task-view--status-face (status)
  "Return an existing face suitable for STATUS."
  (pcase status
    ('running 'success)
    ((or 'waiting-approval 'needs-attention) 'warning)
    ((or 'failed 'interrupted) 'error)
    ((or 'canceled 'queued) 'shadow)
    (_ 'default)))

(defun chat-task-view--tree-items (&optional session-id)
  "Return (TASK . DEPTH) items, optionally filtered by SESSION-ID."
  (let* ((tasks (chat-task-list session-id))
         (known (make-hash-table :test 'equal))
         (children (make-hash-table :test 'equal))
         (visited (make-hash-table :test 'equal))
         roots
         items)
    (dolist (task tasks)
      (puthash (chat-task-id task) task known))
    (dolist (task tasks)
      (let ((parent-id (chat-task-parent-id task)))
        (if (and parent-id (gethash parent-id known))
            (puthash parent-id
                     (append (gethash parent-id children) (list task))
                     children)
          (setq roots (append roots (list task))))))
    (cl-labels
        ((walk (task depth)
           (unless (gethash (chat-task-id task) visited)
             (puthash (chat-task-id task) t visited)
             (setq items (append items (list (cons task depth))))
             (dolist (child (gethash (chat-task-id task) children))
               (walk child (1+ depth))))))
      (dolist (root roots)
        (walk root 0))
      ;; Corrupt or cyclic parent links must remain inspectable.
      (dolist (task tasks)
        (walk task 0)))
    items))

(defun chat-task-view--row (item)
  "Return a tabulated row for task tree ITEM."
  (let* ((task (car item))
         (depth (cdr item))
         (status (chat-task-status task))
         (title (or (chat-task-title task) (chat-task-id task))))
    (list
     (chat-task-id task)
     (vector
      (concat (make-string (* 2 depth) ?\s) title)
      (propertize (symbol-name status)
                  'face (chat-task-view--status-face status))
      (symbol-name (chat-task-kind task))
      (number-to-string (length (chat-task-child-ids task)))
      (or (chat-task-updated-at task) "")))))

(defun chat-task-view-refresh ()
  "Refresh the current task tree."
  (interactive)
  (setq tabulated-list-entries
        (mapcar #'chat-task-view--row
                (chat-task-view--tree-items chat-task-view-session-id)))
  (tabulated-list-print t))

(defun chat-task-view-task-at-point ()
  "Return the durable task represented by the current row."
  (when-let* ((id (tabulated-list-get-id)))
    (chat-task-get id)))

(defun chat-task-view--insert-value (label value)
  "Insert detail LABEL and VALUE."
  (insert (propertize (concat label "\n") 'face 'bold))
  (insert (if (stringp value) value (pp-to-string value)))
  (unless (bolp) (insert "\n"))
  (insert "\n"))

(define-derived-mode chat-task-view-detail-mode special-mode "Chat Task"
  "Major mode for one durable task record.")

(defun chat-task-view-detail-refresh ()
  "Refresh the current task detail buffer."
  (interactive)
  (let ((task (chat-task-get chat-task-view-detail-task-id))
        (inhibit-read-only t))
    (unless task
      (user-error "Task no longer exists"))
    (erase-buffer)
    (insert (propertize (or (chat-task-title task) (chat-task-id task))
                        'face '(:height 1.25 :weight bold))
            "\n\n")
    (chat-task-view--insert-value "Identity" (chat-task-summary task))
    (chat-task-view--insert-value "Resources" (chat-task-resources task))
    (chat-task-view--insert-value "Checkpoint" (chat-task-checkpoint task))
    (chat-task-view--insert-value "Result" (chat-task-result task))
    (chat-task-view--insert-value "Error" (chat-task-error task))
    (chat-task-view--insert-value "Payload" (chat-task-payload task))
    (chat-task-view--insert-value "Metadata" (chat-task-metadata task))
    (goto-char (point-min))))

(defun chat-task-view-show-detail ()
  "Open the task at point in a read-only detail buffer."
  (interactive)
  (let ((task (chat-task-view-task-at-point)))
    (unless task
      (user-error "No task at point"))
    (let ((buffer (get-buffer-create
                   (format "*chat task %s*" (chat-task-id task)))))
      (with-current-buffer buffer
        (chat-task-view-detail-mode)
        (setq chat-task-view-detail-task-id (chat-task-id task))
        (chat-task-view-detail-refresh))
      (pop-to-buffer buffer))))

(defun chat-task-view--session (task)
  "Load TASK's session when it is available."
  (when-let* ((session-id (chat-task-session-id task)))
    (condition-case nil
        (chat-session-load session-id)
      (error nil))))

(defun chat-task-view-cancel ()
  "Cancel the task at point through its owning adapter."
  (interactive)
  (let ((task (chat-task-view-task-at-point)))
    (unless task
      (user-error "No task at point"))
    (when (chat-task-terminal-p task)
      (user-error "Task is already %s" (chat-task-status task)))
    (when (yes-or-no-p (format "Cancel task %s? " (chat-task-id task)))
      (if (eq (chat-task-kind task) 'workflow)
          (let ((chat-tool-caller-current-session
                 (chat-task-view--session task)))
            (chat-work-workflow-cancel (chat-task-id task)))
        (chat-task-cancel (chat-task-id task) "cancelled from task view"))
      (chat-task-view-refresh))))

(defun chat-task-view-resume ()
  "Resume the recoverable task at point through its owning adapter."
  (interactive)
  (let ((task (chat-task-view-task-at-point)))
    (unless task
      (user-error "No task at point"))
    (if (eq (chat-task-kind task) 'workflow)
        (let* ((chat-tool-caller-current-session
                (chat-task-view--session task))
               (checkpoint (chat-task-checkpoint task))
               (decision
                (when (equal (alist-get 'kind checkpoint) "approval")
                  (completing-read "Checkpoint: " '("approve" "reject")
                                   nil t))))
          (chat-work-workflow-resume (chat-task-id task) decision))
      (chat-task-resume (chat-task-id task)))
    (chat-task-view-refresh)))

(define-derived-mode chat-task-view-mode tabulated-list-mode "Chat Tasks"
  "Major mode for browsing durable runtime tasks."
  (setq tabulated-list-format
        [("Task" 40 t)
         ("State" 18 t)
         ("Kind" 12 t)
         ("Children" 8 nil)
         ("Updated" 24 t)])
  (setq tabulated-list-padding 2)
  (tabulated-list-init-header))

(define-key chat-task-view-mode-map (kbd "g") #'chat-task-view-refresh)
(define-key chat-task-view-mode-map (kbd "RET") #'chat-task-view-show-detail)
(define-key chat-task-view-mode-map (kbd "k") #'chat-task-view-cancel)
(define-key chat-task-view-mode-map (kbd "r") #'chat-task-view-resume)
(define-key chat-task-view-detail-mode-map (kbd "g")
            #'chat-task-view-detail-refresh)

;;;###autoload
(defun chat-task-view-open (&optional session-id)
  "Open the durable task tree, optionally filtered by SESSION-ID."
  (interactive)
  (let ((buffer (get-buffer-create "*chat tasks*")))
    (with-current-buffer buffer
      (chat-task-view-mode)
      (setq chat-task-view-session-id session-id)
      (chat-task-view-refresh))
    (pop-to-buffer buffer)))

(provide 'chat-task-view)
;;; chat-task-view.el ends here
