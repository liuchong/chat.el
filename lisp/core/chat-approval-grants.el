;;; chat-approval-grants.el --- What may skip the approval prompt -*- lexical-binding: t -*-
;; Copyright (C) 2026 chat.el contributors
;; Author: chat.el contributors
;; Keywords: chat, tools, safety
;;; Commentary:
;; A grant records that some tool call needs no asking.  Four sources hold
;; them, and they are kept apart on purpose.
;;
;; Before this module, "always allow this" pushed onto the very defcustoms a
;; user had set by hand: `chat-approval-always-approve-tools',
;; `chat-approval-always-approve-directories' and
;; `chat-tool-shell-whitelist'.  Three consequences followed.  A user opening
;; `M-x customize' found entries they never wrote.  A `custom-file' save could
;; write them back, so the program edited the user's configuration without
;; saying so.  And clearing what the program had granted meant clearing what
;; the user had configured along with it, because the two lived in one list.
;;
;; So each source gets its own store, and only one of them is ours to write:
;;
;;   builtin  a constant, read-only patterns the project stands behind
;;   user     a defcustom, written by the user and never by us
;;   runtime  ours, persisted, cleared as a group
;;   session  ours, never persisted, gone when the session ends
;;
;; The session store is what makes "allow for this session" mean the item the
;; person approved.  Without somewhere to put a session-scoped grant, that
;; choice can only be spent on a session-wide switch, which is what it used
;; to do -- one approval of one command turned off asking for every tool.
;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(declare-function chat-session-approval-grants "chat-session" (session))
(declare-function chat-session-set-approval-grants "chat-session" (session grants))
(declare-function chat-session-id "chat-session" (session))

(defgroup chat-approval-grants nil
  "Records of what may run without asking."
  :group 'chat)

(cl-defstruct chat-approval-grant
  "One reason a tool call needs no approval.

TOOL is a tool id, or nil for any tool.  SCOPE says what PATTERN means:

  tool       the whole tool, whatever its arguments; PATTERN is nil
  command    the `command' argument, matched as a whitelist pattern
  directory  every target path lies under PATTERN

SOURCE is where the grant came from and decides whether we may delete it.
CREATED-AT and SESSION-ID are recorded for runtime grants so that a list
grown over months can still be read: without them nobody can tell which
line was added for what, and the only safe move left is to clear all of
them."
  tool
  scope
  pattern
  source
  created-at
  session-id)

(defcustom chat-approval-user-grants nil
  "Grants configured by the user, for any tool.

Each entry is a plist: (:tool SYMBOL :scope SYMBOL :pattern STRING).
`:tool' may be omitted to mean any tool, and `:pattern' is unused when
`:scope' is `tool'.

This list is never written by chat.el.  Use `chat-approval-add-grant' for
grants the program should remember; they go to
`chat-approval-grants-file' instead."
  :type '(repeat (plist :key-type symbol :value-type sexp))
  :group 'chat-approval-grants)

(defcustom chat-approval-grants-file
  (expand-file-name "~/.chat/approvals.eld")
  "Where runtime grants are kept between sessions.

\"Always allow this\" used to last until Emacs exited, because nothing
wrote it down.  A promise the user reasonably read as permanent expired
without notice, and the next session asked again."
  :type 'file
  :group 'chat-approval-grants)

(defcustom chat-approval-grants-persist t
  "Whether runtime grants are written to `chat-approval-grants-file'."
  :type 'boolean
  :group 'chat-approval-grants)

(defvar chat-approval--runtime-grants nil
  "Runtime grants, loaded from `chat-approval-grants-file'.

Ours to write.  Never a defcustom: a variable the program appends to is
not a variable a user can own.")

(defvar chat-approval--runtime-grants-loaded nil
  "Whether runtime grants have been read from disk in this Emacs.")

;;; Pattern matching
;;
;; The semantics are the ones `chat-tool-shell' has always used, and they
;; live here now because grants for other tools need them too.  They are not
;; re-derived: a second set of rules would mean the list a user reads and the
;; list we match against had drifted apart.

(defun chat-approval-grant-pattern-match-p (value pattern)
  "Return non-nil when VALUE matches whitelist PATTERN.

A PATTERN ending in a space matches VALUE at a word boundary, so \"ls \"
covers \"ls\" and \"ls -l\" but not \"lsof\".  Any other PATTERN must equal
VALUE exactly."
  (and (stringp value)
       (stringp pattern)
       (> (length pattern) 0)
       (if (= (aref pattern (1- (length pattern))) ?\s)
           (let ((stem (substring pattern 0 (1- (length pattern)))))
             (and (>= (length value) (length stem))
                  (string-equal (substring value 0 (length stem)) stem)
                  (or (= (length value) (length stem))
                      (= (aref value (length stem)) ?\s))))
         (string-equal value pattern))))

(defun chat-approval-grant--directory-match-p (pattern paths)
  "Return non-nil when every path in PATHS lies under PATTERN."
  (and pattern
       paths
       (let ((root (file-name-as-directory (expand-file-name pattern))))
         (seq-every-p
          (lambda (path)
            (string-prefix-p root (expand-file-name path)))
          paths))))

;;; The four sources

(defun chat-approval-grant--from-plist (entry source)
  "Return a grant built from plist ENTRY attributed to SOURCE."
  (make-chat-approval-grant
   :tool (plist-get entry :tool)
   :scope (or (plist-get entry :scope)
              (if (plist-get entry :pattern) 'command 'tool))
   :pattern (plist-get entry :pattern)
   :source source
   :created-at (plist-get entry :created-at)
   :session-id (plist-get entry :session-id)))

(defun chat-approval-grant--to-plist (grant)
  "Return a writable plist for GRANT."
  (append
   (when (chat-approval-grant-tool grant)
     (list :tool (chat-approval-grant-tool grant)))
   (list :scope (chat-approval-grant-scope grant))
   (when (chat-approval-grant-pattern grant)
     (list :pattern (chat-approval-grant-pattern grant)))
   (when (chat-approval-grant-created-at grant)
     (list :created-at (chat-approval-grant-created-at grant)))
   (when (chat-approval-grant-session-id grant)
     (list :session-id (chat-approval-grant-session-id grant)))))

(defun chat-approval-grant--command-grants (patterns source)
  "Return shell command grants for PATTERNS attributed to SOURCE."
  (mapcar (lambda (pattern)
            (make-chat-approval-grant
             :tool 'shell_execute
             :scope 'command
             :pattern pattern
             :source source))
          patterns))

(defun chat-approval-builtin-grants ()
  "Return grants the project stands behind, which nobody may delete.

The read-only shell patterns in `chat-tool-shell-default-whitelist' are
the whole of it.  Read-only tools are absent by design: they never reach
approval, because `chat-approval-tool-required-p' does not ask about them,
and listing them here would state the same rule in a second place."
  (chat-approval-grant--command-grants
   (and (boundp 'chat-tool-shell-default-whitelist)
        chat-tool-shell-default-whitelist)
   'builtin))

(defun chat-approval-configured-grants ()
  "Return grants the user configured, from new and older variables alike.

The older three are still read.  A user who wrote them has a working
whitelist, and a release that quietly stopped honouring it would take away
permissions without asking, which is the failure this module exists to
prevent."
  (append
   (mapcar (lambda (entry) (chat-approval-grant--from-plist entry 'user))
           chat-approval-user-grants)
   (chat-approval-grant--command-grants
    (and (boundp 'chat-tool-shell-whitelist) chat-tool-shell-whitelist)
    'user)
   (mapcar (lambda (tool-id)
             (make-chat-approval-grant :tool tool-id :scope 'tool :source 'user))
           (and (boundp 'chat-approval-always-approve-tools)
                chat-approval-always-approve-tools))
   ;; The older pair of "auto approve these tools, when the global switch is
   ;; on" is a conditional grant list, so it is read as one.  Left as its own
   ;; branch of the decision it would be a second way to reach the same
   ;; answer, reported differently, and the mode would be decoration.
   (when (and (boundp 'chat-approval-auto-approve-global)
              chat-approval-auto-approve-global
              (boundp 'chat-approval-auto-approve-tools))
     (mapcar (lambda (tool-id)
               (make-chat-approval-grant :tool tool-id :scope 'tool
                                         :source 'user))
             chat-approval-auto-approve-tools))
   (mapcar (lambda (directory)
             (make-chat-approval-grant :scope 'directory
                                       :pattern directory
                                       :source 'user))
           (and (boundp 'chat-approval-always-approve-directories)
                chat-approval-always-approve-directories))))

(defun chat-approval-grants-load ()
  "Read runtime grants from `chat-approval-grants-file'."
  (setq chat-approval--runtime-grants-loaded t)
  (setq chat-approval--runtime-grants
        (when (and chat-approval-grants-persist
                   (file-readable-p chat-approval-grants-file))
          (condition-case nil
              (with-temp-buffer
                (insert-file-contents chat-approval-grants-file)
                (mapcar (lambda (entry)
                          (chat-approval-grant--from-plist entry 'runtime))
                        (car (read-from-string (buffer-string)))))
            (error nil))))
  chat-approval--runtime-grants)

(defun chat-approval-grants-save ()
  "Write runtime grants to `chat-approval-grants-file'."
  (when chat-approval-grants-persist
    (let ((directory (file-name-directory chat-approval-grants-file)))
      (unless (file-directory-p directory)
        (make-directory directory t))
      (with-temp-file chat-approval-grants-file
        (insert ";; chat.el runtime approval grants.  Written by chat.el.\n")
        (let ((print-length nil)
              (print-level nil))
          (prin1 (mapcar #'chat-approval-grant--to-plist
                         chat-approval--runtime-grants)
                 (current-buffer)))
        (insert "\n")))))

(defun chat-approval-runtime-grants ()
  "Return runtime grants, reading the file on first use."
  (unless chat-approval--runtime-grants-loaded
    (chat-approval-grants-load))
  chat-approval--runtime-grants)

(defun chat-approval-session-grants (session)
  "Return grants scoped to SESSION."
  (and session
       (fboundp 'chat-session-approval-grants)
       (chat-session-approval-grants session)))

(defun chat-approval-grants (&optional session)
  "Return every grant in force, SESSION included, tagged by source."
  (append (chat-approval-session-grants session)
          (chat-approval-runtime-grants)
          (chat-approval-configured-grants)
          (chat-approval-builtin-grants)))

;;; Matching a call

(defvar chat-approval-grant-target-paths-function nil
  "Function returning target paths for a tool id and arguments.
Set by `chat-files' so directory grants can be matched without this
module depending on the file tools.")

(defun chat-approval-grant--target-paths (tool-id arguments)
  "Return target paths for TOOL-ID and ARGUMENTS, or nil."
  (when chat-approval-grant-target-paths-function
    (condition-case nil
        (funcall chat-approval-grant-target-paths-function tool-id arguments)
      (error nil))))

(defun chat-approval-grant-applies-p (grant tool-id arguments)
  "Return non-nil when GRANT covers a call to TOOL-ID with ARGUMENTS."
  (and (or (null (chat-approval-grant-tool grant))
           (eq (chat-approval-grant-tool grant) tool-id))
       (pcase (chat-approval-grant-scope grant)
         ('tool t)
         ('command
          (let ((command (cdr (assoc "command" arguments))))
            (and command
                 (or (chat-approval-grant-pattern-match-p
                      command (chat-approval-grant-pattern grant))
                     (chat-approval-grant--command-tail-match-p
                      command grant)))))
         ('directory
          (chat-approval-grant--directory-match-p
           (chat-approval-grant-pattern grant)
           (chat-approval-grant--target-paths tool-id arguments)))
         (_ nil))))

(defvar chat-approval-grant-command-tail-function nil
  "Function returning the runnable tail of a command, or nil.
Set by `chat-tool-shell' so that a whitelisted `cd DIR && cmd' form still
matches the grant for `cmd' without this module knowing shell syntax.")

(defun chat-approval-grant--command-tail-match-p (command grant)
  "Return non-nil when the tail of COMMAND matches GRANT."
  (when chat-approval-grant-command-tail-function
    (let ((tail (condition-case nil
                    (funcall chat-approval-grant-command-tail-function command)
                  (error nil))))
      (and tail
           (chat-approval-grant-pattern-match-p
            tail (chat-approval-grant-pattern grant))))))

(defun chat-approval-grant-match (tool-id arguments &optional session)
  "Return the grant covering TOOL-ID with ARGUMENTS in SESSION, or nil.

Sources are consulted narrowest first, so the grant reported back is the
one closest to the person who made the decision."
  (seq-find (lambda (grant)
              (chat-approval-grant-applies-p grant tool-id arguments))
            (chat-approval-grants session)))

;;; Writing and revoking

(defun chat-approval-add-grant (grant &optional session)
  "Record GRANT and return it.

A grant whose source is `session' is kept on SESSION and dies with it.
Anything else becomes a runtime grant and is written to disk."
  (if (eq (chat-approval-grant-scope grant) nil)
      (error "Grant needs a scope")
    (unless (chat-approval-grant-created-at grant)
      (setf (chat-approval-grant-created-at grant) (current-time)))
    (when (and session
               (null (chat-approval-grant-session-id grant))
               (fboundp 'chat-session-id))
      (setf (chat-approval-grant-session-id grant) (chat-session-id session)))
    (cond
     ((eq (chat-approval-grant-source grant) 'session)
      (when (and session (fboundp 'chat-session-set-approval-grants))
        (chat-session-set-approval-grants
         session
         (cons grant (chat-approval-session-grants session)))))
     (t
      (setf (chat-approval-grant-source grant) 'runtime)
      (chat-approval-runtime-grants)
      (unless (seq-find (lambda (existing)
                          (and (eq (chat-approval-grant-tool existing)
                                   (chat-approval-grant-tool grant))
                               (eq (chat-approval-grant-scope existing)
                                   (chat-approval-grant-scope grant))
                               (equal (chat-approval-grant-pattern existing)
                                      (chat-approval-grant-pattern grant))))
                        chat-approval--runtime-grants)
        (push grant chat-approval--runtime-grants)
        (chat-approval-grants-save))))
    grant))

(defun chat-approval-revoke-grant (grant &optional session)
  "Remove GRANT from the runtime or SESSION store.

Builtin and user grants are refused: they are not ours.  Deleting a user's
configured line from under them would be the same overreach as writing to
it, and the builtin list is code."
  (pcase (chat-approval-grant-source grant)
    ('session
     (when (and session (fboundp 'chat-session-set-approval-grants))
       (chat-session-set-approval-grants
        session
        (delq grant (chat-approval-session-grants session)))
       t))
    ('runtime
     (chat-approval-runtime-grants)
     (setq chat-approval--runtime-grants
           (delq grant chat-approval--runtime-grants))
     (chat-approval-grants-save)
     t)
    (_
     (user-error "Cannot revoke a %s grant; edit your configuration instead"
                 (chat-approval-grant-source grant)))))

(defun chat-approval-clear-runtime-grants ()
  "Forget every runtime grant and write the empty list."
  (interactive)
  (setq chat-approval--runtime-grants nil)
  (setq chat-approval--runtime-grants-loaded t)
  (chat-approval-grants-save)
  (when (called-interactively-p 'interactive)
    (message "Cleared runtime approval grants")))

(defun chat-approval-grant-describe (grant)
  "Return a one-line description of GRANT."
  (format "%-9s %-14s %s"
          (chat-approval-grant-source grant)
          (or (chat-approval-grant-tool grant) "any tool")
          (pcase (chat-approval-grant-scope grant)
            ('tool "whole tool")
            ('command (format "command %S" (chat-approval-grant-pattern grant)))
            ('directory (format "directory %s"
                                (chat-approval-grant-pattern grant)))
            (scope (format "%s" scope)))))

(defun chat-approval-list-grants ()
  "Show every grant in force, with its source."
  (interactive)
  (let ((session (and (boundp 'chat--current-session) chat--current-session)))
    (with-current-buffer (get-buffer-create "*chat approvals*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "Grants in force, narrowest source first.\n")
        (insert "Only runtime and session grants can be revoked here.\n\n")
        (dolist (grant (chat-approval-grants session))
          (insert (chat-approval-grant-describe grant) "\n")))
      (goto-char (point-min))
      (special-mode)
      (display-buffer (current-buffer)))))

(provide 'chat-approval-grants)
;;; chat-approval-grants.el ends here
