;;; chat-extension-trust.el --- Trust boundary for project extensions -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;;; Commentary:

;; Project-local hooks, skills, and agent profiles are executable policy even
;; when their files are declarative.  They therefore share one explicit trust
;; boundary instead of each extension surface inventing its own answer.

;;; Code:

(require 'cl-lib)
(require 'seq)

(defgroup chat-extension-trust nil
  "Trust policy for project-local runtime extensions."
  :group 'chat)

(defcustom chat-extension-trusted-project-roots nil
  "Project roots whose local runtime extensions may be loaded.

Entries are compared by canonical directory name.  Trust applies to the
named project and directories below it; an empty list disables every
project-local extension while leaving user and built-in extensions intact."
  :type '(repeat directory)
  :group 'chat-extension-trust)

(defun chat-extension--canonical-directory (directory)
  "Return a canonical directory name for DIRECTORY."
  (file-name-as-directory
   (file-truename (expand-file-name directory))))

(defun chat-extension-project-trusted-p (project-root)
  "Return non-nil when PROJECT-ROOT is explicitly trusted."
  (when project-root
    (let ((root (chat-extension--canonical-directory project-root)))
      (seq-some
       (lambda (trusted)
         (let ((trusted-root
                (chat-extension--canonical-directory trusted)))
           (or (equal root trusted-root)
               (file-in-directory-p root trusted-root))))
       chat-extension-trusted-project-roots))))

(provide 'chat-extension-trust)
;;; chat-extension-trust.el ends here
