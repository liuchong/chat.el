;;; chat-context.el --- Context window management -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;;; Commentary:
;; Manages conversation context window for long conversations.

;;; Code:

(require 'cl-lib)
(require 'chat-session)
(require 'subr-x)

(defcustom chat-context-max-tokens 8000
  "Maximum tokens to send in a request."
  :type 'integer
  :group 'chat)

(defcustom chat-context-summary-max-chars 600
  "Maximum characters kept in generated context summaries."
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
  (if msgs
      (apply #'+ (mapcar #'chat-context-message-tokens msgs))
    0))

(defun chat-context--message-role-name (msg)
  "Return a readable role name for MSG."
  (string-remove-prefix ":" (symbol-name (chat-message-role msg))))

(defun chat-context--message-snippet (text)
  "Return a short snippet for TEXT."
  (let* ((clean (replace-regexp-in-string "[\n\r\t ]+" " " (or text "")))
         (trimmed (string-trim clean)))
    (truncate-string-to-width trimmed 120 nil nil t)))

(defun chat-context--tool-results-snippet (msg)
  "Return a short snippet of tool results from MSG."
  (when-let ((tool-results (chat-message-tool-results msg)))
    (chat-context--message-snippet
     (mapconcat #'identity tool-results " | "))))

(defun chat-context--summarize-message (msg)
  "Return a one line summary for MSG."
  (let* ((role (chat-context--message-role-name msg))
         (content (chat-context--message-snippet (chat-message-content msg)))
         (tool-results (chat-context--tool-results-snippet msg)))
    (string-trim
     (mapconcat #'identity
                (delq nil
                      (list role
                            (unless (string-blank-p content) content)
                            (when tool-results
                              (format "tool-results %s" tool-results))))
                ": "))))

(defun chat-context--summary-message (msgs)
  "Build a synthetic system summary for MSGS."
  (let* ((lines (mapcar #'chat-context--summarize-message msgs))
         (body (truncate-string-to-width
                (mapconcat #'identity lines "\n")
                chat-context-summary-max-chars nil nil t)))
    (make-chat-message
     :id "context-summary"
     :role :system
     :content (concat "Earlier conversation summary:\n" body)
     :timestamp (current-time))))

(defun chat-context--partition-system-messages (msgs)
  "Split MSGS into leading system messages and the remaining messages."
  (let ((systems nil)
        (rest msgs)
        done)
    (while (and rest (not done))
      (if (eq (chat-message-role (car rest)) :system)
          (progn
            (push (car rest) systems)
            (setq rest (cdr rest)))
        (setq done t)))
    (list (nreverse systems) rest)))

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

(defun chat-context--recent-window-with-summary (msgs max-tokens)
  "Keep leading system messages plus a recent window under MAX-TOKENS."
  (pcase-let* ((`(,system-messages ,conversation)
                (chat-context--partition-system-messages msgs))
               (system-tokens (chat-context-total-tokens system-messages))
               (summary-template (chat-context--summary-message conversation))
               (summary-tokens (chat-context-message-tokens summary-template))
               (latest-message (car (last conversation)))
               (latest-tokens (if latest-message
                                  (chat-context-message-tokens latest-message)
                                0))
               (older-messages (if latest-message
                                   (butlast conversation)
                                 nil))
               (budget-with-summary (max 0 (- max-tokens system-tokens summary-tokens latest-tokens)))
               (recent-older (chat-context-sliding-window older-messages budget-with-summary))
               (recent (append recent-older
                               (if latest-message
                                   (list latest-message)
                                 nil)))
               (omitted-count (- (length conversation) (length recent))))
    (if (<= omitted-count 0)
        (append system-messages recent)
      (append system-messages
              (list (chat-context--summary-message
                     (cl-subseq conversation 0 omitted-count)))
              recent))))

;;;###autoload
(defun chat-context-prepare-messages (msgs &optional max-tokens)
  "Prepare MSGS for API request."
  (let ((max (or max-tokens chat-context-max-tokens)))
    (if (<= (chat-context-total-tokens msgs) max)
        msgs
      (chat-context--recent-window-with-summary msgs max))))

(provide 'chat-context)
;;; chat-context.el ends here
