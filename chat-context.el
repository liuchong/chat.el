;;; chat-context.el --- Context window management -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;;; Commentary:
;; Manages conversation context window for long conversations.

;;; Code:

(require 'chat-session)

(defcustom chat-context-max-tokens 8000
  "Maximum tokens to send in a request."
  :type 'integer
  :group 'chat)

(defun chat-context-count-tokens (text)
  "Estimate token count for TEXT (rough approximation)."
  (if (string-blank-p text)
      0
    (ceiling (/ (length text) 4.0))))

(defun chat-context-message-tokens (msg)
  "Estimate token count for MSG."
  (+ 4 (chat-context-count-tokens (or (chat-message-content msg) ""))))

(defun chat-context-total-tokens (msgs)
  "Calculate total token count for MSGS."
  (apply #'+ (mapcar #'chat-context-message-tokens msgs)))

(defun chat-context-sliding-window (msgs max-tokens)
  "Keep most recent MSGS that fit within MAX-TOKENS."
  (let ((result nil)
        (current 0))
    ;; Add from end until limit
    (dolist (msg (reverse msgs))
      (let ((tokens (chat-context-message-tokens msg)))
        (if (<= (+ current tokens) max-tokens)
            (progn (push msg result)
                   (setq current (+ current tokens)))
          nil)))
    result))

;;;###autoload
(defun chat-context-prepare-messages (msgs &optional max-tokens)
  "Prepare MSGS for API request."
  (let ((max (or max-tokens chat-context-max-tokens)))
    (if (<= (chat-context-total-tokens msgs) max)
        msgs
      (chat-context-sliding-window msgs max))))

(provide 'chat-context)
;;; chat-context.el ends here
