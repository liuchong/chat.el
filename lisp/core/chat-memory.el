;;; chat-memory.el --- Long term memory for chat.el -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;; Author: chat.el contributors
;; Keywords: chat, memory

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Long term memory is an explicit, user curated file injected into
;; every system prompt.  Sessions stay isolated; memory is shared by
;; design because the user owns and edits the file directly.

;;; Code:

(require 'subr-x)

(defcustom chat-memory-file (expand-file-name "memory.md" "~/.chat/")
  "File holding long term memory injected into every system prompt."
  :type 'file
  :group 'chat)

(defcustom chat-memory-max-chars 8000
  "Maximum characters of memory injected into the system prompt."
  :type 'integer
  :group 'chat)

(defun chat-memory-read ()
  "Return the memory file content, or nil when missing or empty."
  (when (file-exists-p chat-memory-file)
    (let ((content (string-trim
                    (with-temp-buffer
                      (insert-file-contents chat-memory-file)
                      (buffer-string)))))
      (unless (string-empty-p content)
        (if (> (length content) chat-memory-max-chars)
            (concat (substring content 0 chat-memory-max-chars)
                    "\n... [memory truncated]")
          content)))))

(defun chat-memory-snippet ()
  "Return the system prompt section for long term memory, or nil."
  (when-let ((content (chat-memory-read)))
    (concat "Long term memory curated by the user:\n" content)))

;;;###autoload
(defun chat-edit-memory ()
  "Open the long term memory file for editing."
  (interactive)
  (find-file chat-memory-file))

(provide 'chat-memory)
;;; chat-memory.el ends here
