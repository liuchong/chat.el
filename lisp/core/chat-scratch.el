;;; chat-scratch.el --- Per-session scratch space -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;;; Commentary:

;; A run often needs somewhere to put something down: a draft it is about
;; to revise, output too large to hold in context, an intermediate file
;; between two commands.  Without a sanctioned place for that, it either
;; carries the material in context, which is what fills a window, or it
;; writes into the project and leaves litter in someone's repository.
;;
;; So there is a directory per session, inside the chat runtime directory
;; and outside any project.  Per session rather than shared, because two
;; runs writing `plan.md' should not collide, and because a session's
;; leftovers can then be identified and removed as a unit.
;;
;; Scratch space is deleted, not kept.  A directory that only grows is the
;; same problem as a context that only grows, and the honest default for
;; something described to the model as temporary is to actually remove it.
;; Pruning is by age and happens when a session opens, which is the moment
;; the answer is cheap to compute and nothing is mid-write.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'chat-session)

(defcustom chat-scratch-directory (expand-file-name "~/.chat/scratch/")
  "Root directory holding per-session scratch space."
  :type 'directory
  :group 'chat)

(defcustom chat-scratch-max-age-days 7
  "How long a session's scratch directory is kept after its last change.

Set to nil to keep scratch space indefinitely, accepting that it grows
without bound."
  :type '(choice (integer :tag "Days") (const :tag "Keep forever" nil))
  :group 'chat)

(defun chat-scratch-session-directory (session &optional create)
  "Return the scratch directory for SESSION, creating it when CREATE.

Returns nil without a session, since scratch space is scoped to one and
a shared fallback would reintroduce the collisions this avoids."
  (when session
    (let ((dir (file-name-as-directory
                (expand-file-name (chat-session-id session)
                                  chat-scratch-directory))))
      (when (and create (not (file-directory-p dir)))
        (make-directory dir t))
      dir)))

(defun chat-scratch--age-days (file)
  "Return how many days ago FILE was last modified."
  (/ (float-time (time-subtract (current-time)
                                (file-attribute-modification-time
                                 (file-attributes file))))
     86400.0))

(defun chat-scratch-prune (&optional keep-session-id)
  "Delete scratch directories older than `chat-scratch-max-age-days'.

KEEP-SESSION-ID is never removed, so a session cannot lose the space it
is using because its own files happen to be old.  Returns the list of
directories removed."
  (when (and chat-scratch-max-age-days
             (file-directory-p chat-scratch-directory))
    (let (removed)
      (dolist (entry (directory-files chat-scratch-directory t
                                      directory-files-no-dot-files-regexp))
        (when (and (file-directory-p entry)
                   (not (equal (file-name-nondirectory entry)
                               keep-session-id))
                   (> (chat-scratch--age-days entry)
                      chat-scratch-max-age-days))
          (ignore-errors
            (delete-directory entry t)
            (push entry removed))))
      (nreverse removed))))

(defun chat-scratch-prompt-note (session &optional terse)
  "Return the prompt block describing SESSION's scratch space, or nil.

Says how long the space lasts.  A run told only that a directory is
writable will use it for things it needed to keep.

With TERSE, keep the path and the fact that it is temporary, which is
the minimum that does not mislead."
  (when-let ((dir (chat-scratch-session-directory session)))
    (if terse
        (format "Scratch space (temporary, writable): %s" dir)
    (concat
     (format "Scratch space: %s\n" dir)
     "Write freely there: drafts, intermediate output, anything too large "
     "to keep in context. Reading a file back costs far less than carrying "
     "it, so prefer writing something down and re-reading the part you "
     "need.\n"
     (if chat-scratch-max-age-days
         (format
          (concat "It is temporary and removed after %d days of no "
                  "changes. Anything worth keeping belongs in the "
                  "project or in shared knowledge, not here.")
          chat-scratch-max-age-days)
       (concat "It is not pruned automatically, but it is still scratch "
               "space: anything worth keeping belongs in the project or "
               "in shared knowledge."))))))

(provide 'chat-scratch)
;;; chat-scratch.el ends here
