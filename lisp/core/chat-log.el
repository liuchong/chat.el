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

(defun chat-log--ensure-file ()
  "Ensure log file exists."
  (let ((dir (file-name-directory chat-log-file)))
    (unless (file-directory-p dir)
      (make-directory dir t))))

(defun chat-log (format-string &rest args)
  "Log message with FORMAT-STRING and ARGS."
  (when chat-log-enabled
    (chat-log--ensure-file)
    (let* ((coding-system-for-write 'utf-8)
           (msg (format "[%s] %s\n"
                       (format-time-string "%Y-%m-%d %H:%M:%S")
                       (apply #'format format-string args))))
      (write-region msg nil chat-log-file t 'silent)
      (when chat-log-echo-to-minibuffer
        (message "[CHAT-LOG] %s" (apply #'format format-string args))))))

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

(defun chat-log-timing-start ()
  "Begin timing a run, discarding any marks left by an abandoned one."
  (setq chat-log--clock (and chat-log-timings (float-time))
        chat-log--marks nil)
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
           (last (car (last marks))))
      (chat-log
       "[TIMING] %s: %s | total %.0fms, gc %d %.0fms%s"
       what
       (mapconcat #'identity
                  (cl-loop for previous = first then mark
                           for mark in (cdr marks)
                           collect (chat-log--timing-phase mark previous))
                  " -> ")
       (- (nth 1 last) (nth 1 first))
       (- (nth 2 last) (nth 2 first))
       (* 1000 (- (nth 3 last) (nth 3 first)))
       (if context (concat " | " context) "")))
    (setq chat-log--marks nil
          chat-log--clock nil)))

(provide 'chat-log)
;;; chat-log.el ends here
