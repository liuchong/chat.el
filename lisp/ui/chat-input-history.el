;;; chat-input-history.el --- Recall what you typed before -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;;; Commentary:

;; A ring of what the user has sent, walked with `M-p' and `M-n' the way
;; every shell and REPL in Emacs does it.
;;
;; The ring is shared across chat buffers rather than kept per buffer.  A
;; question worth asking again is usually worth asking in a different
;; session, and a per-buffer ring would lose it the moment the buffer is
;; killed.
;;
;; Two details are what separate a usable recall from an annoying one.
;; First, a half-written line is not lost: the first `M-p' stashes it and
;; walking back down past the newest entry restores it.  Second, position
;; in the ring is per buffer, so walking history in one session does not
;; move the cursor of another.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'chat-i18n)

(defgroup chat-input-history nil
  "Recall of previously sent chat input."
  :group 'chat)

(defcustom chat-input-history-max 200
  "How many sent inputs to remember."
  :type 'integer
  :group 'chat-input-history)

(defcustom chat-input-history-file
  (expand-file-name "input-history.eld" "~/.chat/")
  "Where the input history is kept between sessions."
  :type 'file
  :group 'chat-input-history)

(defvar chat-input-history nil
  "Sent inputs, newest first.")

(defvar chat-input-history--loaded nil
  "Whether the on-disk history has been read in this Emacs.")

(defvar-local chat-input-history--position nil
  "How far back this buffer has walked, or nil when not walking.")

(defvar-local chat-input-history--draft nil
  "Text that was in the input area when this buffer started walking.")

;; ------------------------------------------------------------------
;; The ring
;; ------------------------------------------------------------------

(defun chat-input-history-add (text)
  "Remember TEXT as sent input.

Blank input is not history.  Neither is a line identical to the one
before it: holding a command down to repeat it should not push out the
rest of the ring."
  (let ((trimmed (string-trim (or text ""))))
    (unless (string-empty-p trimmed)
      (chat-input-history-load)
      (unless (equal trimmed (car chat-input-history))
        (push trimmed chat-input-history)
        (when (> (length chat-input-history) chat-input-history-max)
          (setq chat-input-history
                (seq-take chat-input-history chat-input-history-max)))
        (chat-input-history-save))
      trimmed)))

(defun chat-input-history-entries ()
  "Return remembered inputs, newest first."
  (chat-input-history-load)
  chat-input-history)

;; ------------------------------------------------------------------
;; Persistence
;; ------------------------------------------------------------------

(defun chat-input-history-load ()
  "Read the history from disk once per Emacs session."
  (unless chat-input-history--loaded
    (setq chat-input-history--loaded t)
    (when (file-readable-p chat-input-history-file)
      (condition-case nil
          (with-temp-buffer
            (insert-file-contents chat-input-history-file)
            (let ((stored (read (current-buffer))))
              (when (and (listp stored) (cl-every #'stringp stored))
                (setq chat-input-history stored))))
        ;; A corrupt history is not worth an error on startup; an empty
        ;; ring costs the user a recall, a signal costs them the session.
        (error nil))))
  chat-input-history)

(defun chat-input-history-save ()
  "Write the history to disk."
  (condition-case nil
      (let ((dir (file-name-directory chat-input-history-file)))
        (unless (file-directory-p dir)
          (make-directory dir t))
        (with-temp-file chat-input-history-file
          (let ((print-length nil)
                (print-level nil))
            (prin1 chat-input-history (current-buffer))
            (insert "\n"))))
    (error nil)))

;; ------------------------------------------------------------------
;; Walking it
;; ------------------------------------------------------------------

(defun chat-input-history-reset-position ()
  "Stop walking, so the next `M-p' starts from the newest entry again."
  (setq chat-input-history--position nil)
  (setq chat-input-history--draft nil))

(defun chat-input-history--replace (getter setter text)
  "Put TEXT in the input area, reading the old value with GETTER via SETTER."
  (ignore getter)
  (funcall setter text))

(defun chat-input-history-walk (delta getter setter)
  "Move DELTA steps through history, GETTER and SETTER access the input area.

DELTA of 1 goes further back, -1 comes forward.  GETTER returns the text
currently in the input area; SETTER replaces it.  Returns the new
position, or nil when back at the draft."
  (let* ((entries (chat-input-history-entries))
         (count (length entries)))
    (if (zerop count)
        (progn (message "%s" (chat-i18n 'input-history-empty
                                        "No input history yet"))
               nil)
      ;; Entering the ring: keep whatever was being typed.
      (unless chat-input-history--position
        (setq chat-input-history--draft (funcall getter)))
      (let ((next (+ (or chat-input-history--position -1) delta)))
        (cond
         ((>= next count)
          (message "%s" (chat-i18n 'input-history-oldest
                                   "Beginning of input history"))
          (setq chat-input-history--position (1- count))
          (chat-input-history--replace getter setter (nth (1- count) entries)))
         ((< next 0)
          ;; Walked back out of the ring: the draft returns.
          (chat-input-history--replace
           getter setter (or chat-input-history--draft ""))
          (chat-input-history-reset-position))
         (t
          (setq chat-input-history--position next)
          (chat-input-history--replace getter setter (nth next entries))))
        chat-input-history--position))))

(provide 'chat-input-history)
;;; chat-input-history.el ends here
