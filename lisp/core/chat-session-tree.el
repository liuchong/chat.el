;;; chat-session-tree.el --- Session tree browser for chat.el -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: chat, sessions

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Build and browse parent/branch session trees without changing the
;; existing JSONL format version.

;;; Code:

(require 'cl-lib)
(require 'tabulated-list)
(require 'chat-session)

(cl-defstruct chat-session-tree-node
  session
  children
  (depth 0))

(defun chat-session-tree--parent-id (session)
  "Return parent id for SESSION."
  (chat-session-parent-session-id session))

(defun chat-session-tree--newer-node-p (a b)
  "Return non-nil when node A is newer than node B."
  (time-less-p
   (chat-session-updated-at (chat-session-tree-node-session b))
   (chat-session-updated-at (chat-session-tree-node-session a))))

(defun chat-session-tree-build (&optional sessions)
  "Build session tree roots from SESSIONS or all saved sessions."
  (let* ((all (or sessions (chat-session-list)))
         (by-id (make-hash-table :test 'equal))
         (roots nil))
    (dolist (session all)
      (puthash (chat-session-id session)
               (make-chat-session-tree-node :session session)
               by-id))
    (dolist (session all)
      (let* ((node (gethash (chat-session-id session) by-id))
             (parent-id (chat-session-tree--parent-id session))
             (parent (and parent-id (gethash parent-id by-id))))
        (if parent
            (push node (chat-session-tree-node-children parent))
          (push node roots))))
    (cl-labels ((sort-node (node depth)
                  (setf (chat-session-tree-node-depth node) depth)
                  (setf (chat-session-tree-node-children node)
                        (sort (chat-session-tree-node-children node)
                              #'chat-session-tree--newer-node-p))
                  (dolist (child (chat-session-tree-node-children node))
                    (sort-node child (1+ depth)))))
      (setq roots (sort roots #'chat-session-tree--newer-node-p))
      (dolist (root roots)
        (sort-node root 0)))
    roots))

(defun chat-session-tree-flatten (&optional sessions)
  "Return tree nodes from SESSIONS in display order."
  (let (nodes)
    (cl-labels ((walk
                 (node)
                 (push node nodes)
                 (dolist (child (chat-session-tree-node-children node))
                   (walk child))))
      (dolist (root (chat-session-tree-build sessions))
        (walk root)))
    (nreverse nodes)))

(defvar-local chat-session-tree--sessions nil
  "Sessions shown in the current tree buffer.")

(defun chat-session-tree--row (node)
  "Return a tabulated-list row for NODE."
  (let* ((session (chat-session-tree-node-session node))
         (depth (chat-session-tree-node-depth node))
         (prefix (make-string (* 2 depth) ?\s))
         (name (concat prefix (chat-session-name session)))
         (updated (format-time-string
                   "%Y-%m-%d %H:%M"
                   (chat-session-updated-at session))))
    (list
     (chat-session-id session)
     (vector name
             (or (chat-session-branch-id session) "")
             (or (chat-session-leaf-message-id session) "")
             (or (chat-session-parent-session-id session) "")
             updated))))

(defun chat-session-tree-refresh ()
  "Refresh the current session tree buffer."
  (setq tabulated-list-entries
        (mapcar #'chat-session-tree--row
                (chat-session-tree-flatten chat-session-tree--sessions)))
  (tabulated-list-print t))

(defun chat-session-tree-session-at-point ()
  "Return the session represented by the current row."
  (when-let ((id (tabulated-list-get-id)))
    (chat-session-load id)))

(defun chat-session-tree-recover-interrupted ()
  "Resolve the interrupted tool run for the session at point."
  (interactive)
  (let ((session (chat-session-tree-session-at-point)))
    (unless session
      (user-error "No session at point"))
    (unless (chat-session-recovery-state session)
      (user-error "Session has no interrupted tool run"))
    (let ((action
           (intern
            (completing-read
             "Recovery action: "
             '("mark-failed" "discard" "keep")
             nil t nil nil "mark-failed"))))
      (chat-session-recover-interrupted-run session action)
      (setq chat-session-tree--sessions (chat-session-list))
      (chat-session-tree-refresh)
      (message "Recovery action applied: %s" action))))

(define-derived-mode chat-session-tree-mode tabulated-list-mode "Chat Session Tree"
  "Major mode for browsing chat session branches."
  (setq tabulated-list-format
        [("Name" 32 t)
         ("Branch" 20 t)
         ("Leaf" 24 t)
         ("Parent" 20 t)
         ("Updated" 16 t)])
  (setq tabulated-list-padding 2)
  (define-key chat-session-tree-mode-map
              (kbd "R") #'chat-session-tree-recover-interrupted)
  (tabulated-list-init-header))

;;;###autoload
(defun chat-session-tree-open ()
  "Open a tabulated-list browser for saved chat sessions."
  (interactive)
  (let ((buffer (get-buffer-create "*chat sessions tree*")))
    (with-current-buffer buffer
      (chat-session-tree-mode)
      (setq chat-session-tree--sessions (chat-session-list))
      (chat-session-tree-refresh))
    (pop-to-buffer buffer)))

(provide 'chat-session-tree)
;;; chat-session-tree.el ends here
