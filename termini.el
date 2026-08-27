;;; termini.el --- Optional Termini control surface -*- lexical-binding: t; -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: tools, processes

;;; Commentary:

;; Load this entry point explicitly to control Termini RuntimeSessions and jobs
;; from Emacs.  Loading chat.el alone does not load or start this integration.

;;; Code:

(defconst termini-root-directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Repository root directory for this Termini integration.")

(dolist (directory '("lisp/core" "lisp/ui"))
  (add-to-list 'load-path
               (expand-file-name directory termini-root-directory)))

(require 'chat-termini-bridge)
(require 'chat-termini-view)

(provide 'termini)
;;; termini.el ends here
