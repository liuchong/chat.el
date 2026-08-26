;;; chat-shell-builtins.el --- Shell builtins that must run in Lisp -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;;; Commentary:

;; Every command typed at the chat prompt goes to a real shell, except the
;; handful that change the state of the session running them.  A subprocess
;; cannot move its parent's working directory or set its parent's
;; environment, so `cd' in a subshell succeeds and changes nothing that
;; outlives it.  Those commands have to be interpreted here.
;;
;; That is the whole boundary, and it is worth stating because it decides
;; what belongs in this file: a builtin lives here if and only if its
;; effect must survive the command that issued it.  `cd', `pushd', `popd',
;; `dirs', `export' and `unset' qualify.  `ls' does not, and neither does
;; anything else -- the shell is better at those than we will ever be, and
;; reimplementing them would mean maintaining a worse shell inside a chat
;; client.
;;
;; The state lives per chat buffer, so two sessions can sit in different
;; directories with different environments, which is the point of having
;; the directory belong to the session at all.

;;; Code:

(require 'subr-x)
(require 'chat-i18n)

(defvar-local chat-shell-previous-directory nil
  "Directory this buffer was in before the last change, or nil.

What `cd -' returns to, and what a shell keeps in OLDPWD.")

(defvar-local chat-shell-directory-stack nil
  "Directories pushed with `pushd', innermost first.")

(defvar-local chat-shell-environment nil
  "Alist of environment variables set with `export' in this buffer.

Each command runs in a new subshell, so an `export' would otherwise reach
only the process that performed it and be gone by the next line -- the
variable appears to be set and then is not, which is worse than refusing
to set it.")

;; ------------------------------------------------------------------
;; Parsing
;; ------------------------------------------------------------------

(defconst chat-shell-builtins--unsafe "[;&|<>`$]"
  "Shell metacharacters that mean a line is not a plain builtin.

`cd /tmp && ls' has to reach a shell, because the part after `&&' is not
ours to run.  Matching on these is what keeps this file from quietly
swallowing half of a compound command.")

(defun chat-shell-builtins-parse (command)
  "Return a plist describing COMMAND when it is a builtin, else nil.

The plist carries `:builtin' and, where the builtin takes one, `:arg'."
  (let ((trimmed (string-trim (or command ""))))
    (unless (string-match-p chat-shell-builtins--unsafe trimmed)
      (cond
       ((string-match "\\`cd\\(?:[ \t]+\\(.*\\)\\)?\\'" trimmed)
        (list :builtin 'cd :arg (string-trim (or (match-string 1 trimmed) ""))))
       ((string-match "\\`pushd\\(?:[ \t]+\\(.*\\)\\)?\\'" trimmed)
        (list :builtin 'pushd
              :arg (string-trim (or (match-string 1 trimmed) ""))))
       ((string-match-p "\\`popd\\'" trimmed)
        (list :builtin 'popd))
       ((string-match-p "\\`dirs\\'" trimmed)
        (list :builtin 'dirs))
       ((string-match "\\`export[ \t]+\\(.+\\)\\'" trimmed)
        (list :builtin 'export :arg (string-trim (match-string 1 trimmed))))
       ((string-match "\\`unset[ \t]+\\(.+\\)\\'" trimmed)
        (list :builtin 'unset :arg (string-trim (match-string 1 trimmed))))
       (t nil)))))

;; ------------------------------------------------------------------
;; Directories
;; ------------------------------------------------------------------

(defun chat-shell-builtins-resolve-directory (arg)
  "Return the directory ARG names, or a cons of `error' and a reason.

ARG follows the shell: empty means home, `-' means where we were before."
  (cond
   ((or (null arg) (string-empty-p arg)) "~")
   ((string= arg "-")
    (or chat-shell-previous-directory
        (cons 'error (chat-i18n 'shell-no-previous-directory
                                "cd: OLDPWD not set"))))
   (t arg)))

(defun chat-shell-builtins-record-departure (directory)
  "Remember DIRECTORY as the one to come back to with `cd -'."
  (setq chat-shell-previous-directory directory))

;; ------------------------------------------------------------------
;; Environment
;; ------------------------------------------------------------------

(defun chat-shell-builtins-parse-assignment (text)
  "Return a cons of name and value for TEXT, or nil when it is not one.

`export FOO=bar' assigns.  `export FOO' alone exports a variable already
in the environment, which for our purposes is a no-op, so it returns the
name with its current value rather than emptying it."
  (cond
   ((string-match "\\`\\([A-Za-z_][A-Za-z0-9_]*\\)=\\(.*\\)\\'" text)
    (cons (match-string 1 text)
          (chat-shell-builtins--unquote (match-string 2 text))))
   ((string-match "\\`\\([A-Za-z_][A-Za-z0-9_]*\\)\\'" text)
    (cons (match-string 1 text)
          (or (getenv (match-string 1 text)) "")))
   (t nil)))

(defun chat-shell-builtins--unquote (value)
  "Strip one layer of matching quotes from VALUE."
  (if (and (> (length value) 1)
           (or (and (string-prefix-p "\"" value) (string-suffix-p "\"" value))
               (and (string-prefix-p "'" value) (string-suffix-p "'" value))))
      (substring value 1 -1)
    value))

(defun chat-shell-builtins-set-variable (name value)
  "Record NAME as VALUE for later commands in this buffer."
  (setq chat-shell-environment
        (cons (cons name value)
              (assoc-delete-all name chat-shell-environment)))
  value)

(defun chat-shell-builtins-unset-variable (name)
  "Forget NAME in this buffer."
  (setq chat-shell-environment
        (assoc-delete-all name chat-shell-environment))
  name)

(defun chat-shell-builtins-process-environment ()
  "Return `process-environment' extended with this buffer's exports.

Prepended, since a later entry of the same name is shadowed by an earlier
one, so an export made here wins over an inherited value."
  (append (mapcar (lambda (pair) (format "%s=%s" (car pair) (cdr pair)))
                  chat-shell-environment)
          process-environment))

(defun chat-shell-builtins-environment-report ()
  "Return the exports of this buffer as lines, or nil when there are none."
  (when chat-shell-environment
    (mapconcat (lambda (pair) (format "%s=%s" (car pair) (cdr pair)))
               (reverse chat-shell-environment)
               "\n")))

;; ------------------------------------------------------------------
;; The directory stack
;; ------------------------------------------------------------------

(defun chat-shell-builtins-push-directory (directory)
  "Push DIRECTORY onto this buffer's directory stack."
  (push directory chat-shell-directory-stack)
  directory)

(defun chat-shell-builtins-pop-directory ()
  "Pop the directory stack, returning the directory or nil when empty."
  (pop chat-shell-directory-stack))

(defun chat-shell-builtins-directory-stack-report (current)
  "Return the stack as a shell would print it, CURRENT first."
  (mapconcat #'chat-shell-builtins--abbreviate
             (cons current chat-shell-directory-stack)
             " "))

(defun chat-shell-builtins--abbreviate (directory)
  "Return DIRECTORY with the home directory shortened to `~'."
  (abbreviate-file-name (directory-file-name directory)))

(provide 'chat-shell-builtins)
;;; chat-shell-builtins.el ends here
