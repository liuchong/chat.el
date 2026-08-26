;;; chat-log.el --- Logging for chat.el -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: logging, debug

;;; Commentary:

;; Simple logging for chat.el operations.
;; Logs to ~/.chat/chat.log

;;; Code:

(require 'cl-lib)

(defcustom chat-log-enabled t
  "Enable logging."
  :type 'boolean
  :group 'chat)

(defcustom chat-log-file "~/.chat/chat.log"
  "Log file path."
  :type 'file
  :group 'chat)

(defcustom chat-log-echo-to-minibuffer nil
  "Whether chat log entries should also be echoed to the minibuffer."
  :type 'boolean
  :group 'chat)

(defcustom chat-log-max-total-bytes (* 256 1024 1024)
  "Bytes the diagnostic log and its rotations may occupy together.

Uncapped, this file reached 119MB, and nothing about it was recoverable:
it held every session at once, so there was no part of it that could be
dropped as belonging to something finished."
  :type 'integer
  :group 'chat)

(defvar chat-log--day nil
  "Day the active log file belongs to, or nil if not yet checked.")

(defun chat-log--ensure-file ()
  "Ensure log file exists."
  (let ((dir (file-name-directory chat-log-file)))
    (unless (file-directory-p dir)
      (make-directory dir t))))

(defun chat-log--rotations ()
  "Return existing rotations of the log, oldest first."
  (let* ((file (expand-file-name chat-log-file))
         (directory (file-name-directory file))
         (base (file-name-nondirectory file)))
    (sort (and (file-directory-p directory)
               (directory-files directory t
                                (concat "\\`" (regexp-quote base)
                                        "\\.[0-9-]+\\'")))
          #'string<)))

(defun chat-log--prune ()
  "Drop the oldest rotations until the log's total fits its cap."
  (let* ((files (chat-log--rotations))
         (total (cl-loop for f in files
                         sum (or (file-attribute-size (file-attributes f)) 0))))
    (while (and files (> total chat-log-max-total-bytes))
      (let ((oldest (car files)))
        (setq total (- total (or (file-attribute-size
                                  (file-attributes oldest))
                                 0))
              files (cdr files))
        (ignore-errors (delete-file oldest))))))

(defun chat-log--maybe-rotate ()
  "Start a new log file when the day has changed.

Per day rather than per size, because the question asked of this file is
always \"what happened when I saw the problem\", and a date answers it
where a sequence number does not."
  (let ((today (format-time-string "%Y-%m-%d")))
    (unless (equal today chat-log--day)
      (setq chat-log--day today)
      (let ((file (expand-file-name chat-log-file)))
        (when (file-exists-p file)
          (let ((stamp (format-time-string
                        "%Y-%m-%d"
                        (file-attribute-modification-time
                         (file-attributes file)))))
            (unless (equal stamp today)
              (ignore-errors
                (rename-file file (concat file "." stamp) t))))))
      (chat-log--prune))))

(defun chat-log--write (format-string args)
  "Append FORMAT-STRING formatted with ARGS to the diagnostic log."
  (chat-log--ensure-file)
  (chat-log--maybe-rotate)
  (let* ((coding-system-for-write 'utf-8)
         (text (apply #'format format-string args)))
    (write-region (format "[%s] %s\n"
                          (format-time-string "%Y-%m-%d %H:%M:%S")
                          text)
                  nil chat-log-file t 'silent)
    (when chat-log-echo-to-minibuffer
      (message "[CHAT-LOG] %s" text))))

(defmacro chat-log (format-string &rest args)
  "Log FORMAT-STRING with ARGS, if logging is on.

A macro so that ARGS are not evaluated when it is off.  As a function,
every argument was computed and thrown away: the request builder formatted
a 250KB payload on each send to pass it to a call that might discard it,
which is work that logging was supposed to only observe."
  `(when chat-log-enabled
     (chat-log--write ,format-string (list ,@args))))

;; ------------------------------------------------------------------
;; Phase Timing
;; ------------------------------------------------------------------

;; A hitch someone else feels cannot be reproduced by benchmarking this
;; machine: the cost lives in their heap, their exec-path, their session.
;; So the path measures itself where the complaint happens and leaves one
;; line behind.  The clock lives here, in the layer everything already
;; depends on, so the transport and the request builder can mark their own
;; phases instead of hiding inside whatever the caller wrapped them in.

(defcustom chat-log-timings t
  "Whether timed paths record where their time went.

One log line per run, which is what makes a hitch diagnosable after the
fact rather than only while someone is watching for it."
  :type 'boolean
  :group 'chat)

(defvar chat-log--clock nil
  "Start time of the run in progress, or nil when nothing is timed.")

(defvar chat-log--marks nil
  "Reversed list of marks for the run in progress.
Each mark is (LABEL MILLISECONDS COLLECTIONS SECONDS-COLLECTING), all
measured from the start of the run.")

(defvar chat-log--timing-session nil
  "Session the run in progress belongs to, or nil if it belongs to none.

A timing line in a global file answers \"was it slow\"; the same line
attached to a session answers \"was it slow when I asked that\", which is
the question anyone actually has.")

(defun chat-log-timing-start (&optional session-id)
  "Begin timing a run, discarding any marks left by an abandoned one.
SESSION-ID, when given, files the report with that session."
  (setq chat-log--clock (and chat-log-timings (float-time))
        chat-log--marks nil
        chat-log--timing-session session-id)
  ;; A phase is charged for the collection that happened while it ran, so
  ;; the mark that looks expensive one time in ten can say whether it did
  ;; the work or merely paid for everyone else's garbage.
  (chat-log-timing-mark "begin"))

(defun chat-log-timing-mark (label)
  "Record LABEL as reached, with the time since the run began.
Does nothing outside a timed run, so callers deep in the stack need not
know whether anyone is measuring."
  (when chat-log--clock
    (push (list label
                (* 1000 (- (float-time) chat-log--clock))
                gcs-done
                gc-elapsed)
          chat-log--marks)))

(defun chat-log--timing-phase (mark previous)
  "Describe MARK as a phase following PREVIOUS, or nil for the first mark."
  (when previous
    (let ((collections (- (nth 2 mark) (nth 2 previous)))
          (collecting (- (nth 3 mark) (nth 3 previous))))
      (format "%s %.0f%s"
              (nth 0 mark)
              (- (nth 1 mark) (nth 1 previous))
              (if (> collections 0)
                  (format " [gc %d, %.0fms]" collections (* 1000 collecting))
                "")))))

(defun chat-log-timing-report (what &optional context)
  "Log the marks collected for this run, described as WHAT.
CONTEXT is an optional string appended to the line, for whatever the
caller knows about the environment that the marks do not say."
  (when (and chat-log--clock (cdr chat-log--marks))
    (let* ((marks (nreverse chat-log--marks))
           (first (car marks))
           (last (car (last marks)))
           (phases (cl-loop for previous = first then mark
                            for mark in (cdr marks)
                            collect (chat-log--timing-phase mark previous)))
           (total (- (nth 1 last) (nth 1 first)))
           (collections (- (nth 2 last) (nth 2 first)))
           (collecting (* 1000 (- (nth 3 last) (nth 3 first)))))
      (chat-log
       "[TIMING] %s: %s | total %.0fms, gc %d %.0fms%s"
       what (mapconcat #'identity phases " -> ")
       total collections collecting
       (if context (concat " | " context) ""))
      (when (and chat-log--timing-session
                 (fboundp 'chat-session-wire-record))
        (funcall 'chat-session-wire-record
                 chat-log--timing-session 'timing
                 (list (cons 'what what)
                       (cons 'total_ms (round total))
                       (cons 'gc_count collections)
                       (cons 'gc_ms (round collecting))
                       (cons 'phases (mapconcat #'identity phases " -> "))))))
    (setq chat-log--marks nil
          chat-log--clock nil
          chat-log--timing-session nil)))

(provide 'chat-log)
;;; chat-log.el ends here
