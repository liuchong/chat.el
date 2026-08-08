;;; chat-project.el --- Project instruction discovery -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;; Author: chat.el contributors
;; Keywords: chat, project, agents.md

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Project instruction discovery following the pi resource-loader
;; design: an optional global file first, then AGENTS.md files from
;; the filesystem root down to the start directory, root-most first.
;; Content is merged with source annotations and capped in size.

;;; Code:

(require 'seq)
(require 'subr-x)

(defcustom chat-project-agents-file-names '("AGENTS.md" "AGENTS.MD" "agents.md")
  "File names considered project instruction files, in priority order."
  :type '(repeat string)
  :group 'chat)

(defcustom chat-project-global-agents-file (expand-file-name "AGENTS.md" "~/.chat/")
  "Optional global project instructions file included before local ones."
  :type 'file
  :group 'chat)

(defcustom chat-project-instructions-max-chars 32768
  "Maximum characters of merged project instructions."
  :type 'integer
  :group 'chat)

(defun chat-project--agents-file-in (directory)
  "Return the first existing project instruction file in DIRECTORY, or nil."
  (seq-find (lambda (path) (file-exists-p path))
            (mapcar (lambda (name) (expand-file-name name directory))
                    chat-project-agents-file-names)))

(defun chat-project-collect-agents-files (start-directory)
  "Collect project instruction files above START-DIRECTORY.
Walks from START-DIRECTORY up to the filesystem root and returns
paths root-most first, without duplicates."
  (let ((dir (file-truename start-directory))
        (files nil))
    (while dir
      (when-let ((found (chat-project--agents-file-in dir)))
        (unless (member found files)
          (push found files)))
      (let ((parent (file-name-directory (directory-file-name dir))))
        (setq dir (and parent
                       (not (equal parent dir))
                       parent))))
    files))

(defun chat-project-instructions (start-directory)
  "Return merged project instructions for START-DIRECTORY, or nil.
The global instructions file comes first, then local files from the
filesystem root down to START-DIRECTORY, each with a source
annotation.  The result is capped by
`chat-project-instructions-max-chars'."
  (let ((files (delete-dups
                (append
                 (when (file-exists-p chat-project-global-agents-file)
                   (list chat-project-global-agents-file))
                 (chat-project-collect-agents-files start-directory)))))
    (when files
      (let ((text
             (string-join
              (mapcar
               (lambda (file)
                 (format ";; Project instructions from %s:\n%s"
                         file
                         (string-trim-right
                          (with-temp-buffer
                            (insert-file-contents file)
                            (buffer-string)))))
               files)
              "\n\n")))
        (if (> (length text) chat-project-instructions-max-chars)
            (concat (substring text 0 chat-project-instructions-max-chars)
                    "\n... [project instructions truncated]")
          text)))))

(provide 'chat-project)
;;; chat-project.el ends here
