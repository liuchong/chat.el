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
(require 'chat-context-resident)

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

(defun chat-project--merged-text (start-directory)
  "Return the merged instruction files for START-DIRECTORY, or nil."
  (let ((files (delete-dups
                (append
                 (when (file-exists-p chat-project-global-agents-file)
                   (list chat-project-global-agents-file))
                 (chat-project-collect-agents-files start-directory)))))
    (when files
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
       "\n\n"))))

(defun chat-project-instructions-partitioned (start-directory)
  "Return instructions for START-DIRECTORY split by declared residency.

The result is a plist of `:resident' and `:compactable', either of which
may be nil.  A file marks the spans it needs kept verbatim; see
`chat-context-resident-parse' for the syntax.

The size cap applies to the compactable part alone.  Truncating the
merged text by character count, as this once did, cuts whatever happens
to sit at the end -- so a long instructions file lost its last rules
without saying so, which is a worse outcome than summarizing them."
  (when-let ((text (chat-project--merged-text start-directory)))
    (let* ((parts (chat-context-resident-partition text))
           (resident (plist-get parts :resident))
           (compactable (plist-get parts :compactable)))
      (list :resident resident
            :compactable
            (if (and compactable
                     (> (length compactable)
                        chat-project-instructions-max-chars))
                (concat (substring compactable
                                   0 chat-project-instructions-max-chars)
                        "\n... [project instructions truncated]")
              compactable)))))

(defun chat-project-instructions (start-directory)
  "Return merged project instructions for START-DIRECTORY, or nil.
The global instructions file comes first, then local files from the
filesystem root down to START-DIRECTORY, each with a source annotation.

Declared resident spans come first and are exempt from the
`chat-project-instructions-max-chars' cap, so a file that asks for a
rule to be kept verbatim does not lose it to a size limit.  Callers that
can route the two parts differently should use
`chat-project-instructions-partitioned' instead."
  (when-let ((parts (chat-project-instructions-partitioned start-directory)))
    (let ((pieces (delq nil (list (plist-get parts :resident)
                                  (plist-get parts :compactable)))))
      (and pieces (string-join pieces "\n\n")))))

(provide 'chat-project)
;;; chat-project.el ends here
