;;; chat-log.el --- Logging for chat.el -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: logging, debug

;;; Commentary:

;; Simple logging for chat.el operations.
;; Logs to ~/.chat/chat.log

;;; Code:

(defcustom chat-log-enabled t
  "Enable logging."
  :type 'boolean
  :group 'chat)

(defcustom chat-log-file "~/.chat/chat.log"
  "Log file path."
  :type 'file
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
      ;; Also message to minibuffer for debugging
      (message "[CHAT-LOG] %s" (apply #'format format-string args)))))

(provide 'chat-log)
;;; chat-log.el ends here
