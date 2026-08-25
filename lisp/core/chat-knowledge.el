;;; chat-knowledge.el --- Shared accumulated knowledge -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;;; Commentary:

;; Every session starts over.  Whatever was worked out last time -- that a
;; build needs a flag, that a service answers on an odd port, that an
;; approach was tried and failed -- is either rediscovered or lost.  A
;; place to write those down, shared across sessions and projects, is what
;; makes the tool better the more it is used.
;;
;; This is not the long term memory file.  That one is curated by the user
;; and states what the assistant should do; this one accumulates what it
;; found out.  Keeping them apart matters because the trust differs: a
;; user instruction is authoritative, and a note a run wrote about its own
;; findings is evidence that may be stale or wrong.
;;
;; The important design constraint is that this grows without limit, and
;; anything injected into every prompt has to not grow.  So the prompt
;; carries an index -- the note names and their one-line summaries -- and
;; the bodies are read on demand.  Injecting the whole store would put a
;; monotonically growing block into the fixed region of the context and
;; slowly starve the work, which is exactly the failure the context budget
;; exists to prevent.  An index costs a line per note and stays useful at
;; a hundred of them.
;;
;; A note's first line is its title, which is what the index shows.  That
;; makes the file format its own metadata and keeps the store editable by
;; hand.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

;; The tool forge lives a layer up and requires core modules, so it is
;; declared rather than required: registration is guarded by `fboundp' and
;; happens after both layers are loaded.
(declare-function chat-tool-forge-register "chat-tool-forge" (tool))
(declare-function make-chat-forged-tool "chat-tool-forge" (&rest slots))

(defcustom chat-knowledge-directory (expand-file-name "~/.chat/knowledge/")
  "Directory holding shared notes accumulated across sessions."
  :type 'directory
  :group 'chat)

(defcustom chat-knowledge-index-max-entries 60
  "How many notes the prompt index may list.

The index is in every request, so it has to have a ceiling.  Past this
the most recently changed notes are listed, on the grounds that a store
this large is being used and recency is the only ordering available
without reading every body."
  :type 'integer
  :group 'chat)

(defcustom chat-knowledge-note-max-chars 20000
  "Longest note body a read returns whole."
  :type 'integer
  :group 'chat)

(defconst chat-knowledge-file-extension ".md"
  "Extension used for knowledge notes.")

;; ------------------------------------------------------------------
;; Naming
;; ------------------------------------------------------------------

(defun chat-knowledge--slug (name)
  "Return NAME reduced to a safe file base.

Paths are built from model-supplied names, so this has to reject
traversal rather than sanitize around it."
  (let ((base (downcase
               (replace-regexp-in-string
                "[^[:alnum:]._-]+" "-"
                (string-trim (or name ""))))))
    (setq base (replace-regexp-in-string "\\`[.-]+\\|[.-]+\\'" "" base))
    (unless (string-empty-p base)
      base)))

(defun chat-knowledge-note-path (name)
  "Return the file path for note NAME, or nil when NAME is unusable."
  (when-let ((slug (chat-knowledge--slug name)))
    (expand-file-name (concat slug chat-knowledge-file-extension)
                      chat-knowledge-directory)))

(defun chat-knowledge--notes ()
  "Return the note files, most recently changed first."
  (when (file-directory-p chat-knowledge-directory)
    (sort (directory-files chat-knowledge-directory t
                           (concat "\\"
                                   chat-knowledge-file-extension "\\'"))
          (lambda (a b)
            (time-less-p (file-attribute-modification-time
                          (file-attributes b))
                         (file-attribute-modification-time
                          (file-attributes a)))))))

(defun chat-knowledge--title (file)
  "Return the first non-blank line of FILE as its title."
  (with-temp-buffer
    (insert-file-contents file nil 0 4096)
    (goto-char (point-min))
    (let (title)
      (while (and (not title) (not (eobp)))
        (let ((line (string-trim
                     (replace-regexp-in-string
                      "\\`#+[ \t]*" ""
                      (buffer-substring-no-properties
                       (line-beginning-position) (line-end-position))))))
          (unless (string-empty-p line)
            (setq title line)))
        (forward-line 1))
      title)))

;; ------------------------------------------------------------------
;; Index for the prompt
;; ------------------------------------------------------------------

(defun chat-knowledge-index ()
  "Return the note index as a list of (NAME . TITLE)."
  (let ((files (chat-knowledge--notes)))
    (when (> (length files) chat-knowledge-index-max-entries)
      (setq files (cl-subseq files 0 chat-knowledge-index-max-entries)))
    (mapcar
     (lambda (file)
       (cons (file-name-base file)
             (or (chat-knowledge--title file) "")))
     files)))

(defun chat-knowledge-prompt-note (&optional terse)
  "Return the prompt block for shared knowledge, or nil when empty.

Lists what exists without including it.  The store grows with use and
anything present in every request must not, so the bodies stay on disk
until asked for.

With TERSE, keep the index and drop the guidance.  The index is what
makes the store reachable at all; the advice about when to write can be
inferred from the tool descriptions."
  (let ((index (chat-knowledge-index)))
    (if terse
        (concat
         (format "Shared knowledge (knowledge_read/write/search): %s"
                 chat-knowledge-directory)
         (when index
           (concat "\n"
                   (mapconcat (lambda (entry)
                                (format "- %s: %s" (car entry) (cdr entry)))
                              index "\n"))))
    (concat
     (format "Shared knowledge: %s\n" chat-knowledge-directory)
     "Notes here persist across every session and every project, including "
     "projects unrelated to this one and belonging to different parties. "
     "That is what makes them valuable and what constrains them: a note "
     "must be general, reusable knowledge that stays true away from the "
     "work that produced it.\n"
     "\n"
     "Write about the technique, not the case. \"A tool's parameters "
     "arrive positionally, so an implementation reading a keyword list "
     "mis-binds silently\" belongs here. \"Service X on host Y needs flag "
     "Z\" does not -- it is useless elsewhere and it carries information "
     "out of the project it came from. Never record project or repository "
     "names, paths, hostnames, internal identifiers, credentials, or "
     "anything that would tell a reader which codebase you were in.\n"
     "\n"
     "The bar is high on purpose: prefer writing nothing. A note earns its "
     "place only if it would still help someone starting a different task "
     "in a different codebase. When in doubt, leave it out -- a small "
     "store of durable observations is worth more than a large one that "
     "has to be distrusted.\n"
     "\n"
     "These are your own findings, not user instructions: treat them as "
     "evidence that may be stale, and correct a note when you find it "
     "wrong.\n"
     (if index
         (concat
          "\nExisting notes, by name and title. Use knowledge_read to "
          "open one:\n"
          (mapconcat (lambda (entry)
                       (format "- %s: %s" (car entry) (cdr entry)))
                     index "\n"))
       "\nThere are no notes yet. Use knowledge_write to start one.")))))

;; ------------------------------------------------------------------
;; Reading and writing
;; ------------------------------------------------------------------

(defcustom chat-knowledge-reject-patterns
  '("-----BEGIN [A-Z ]*PRIVATE KEY"
    "\\(?:api[_-]?key\\|secret\\|password\\|passwd\\|token\\)[\"' ]*[:=][\"' ]*[[:graph:]]\\{12,\\}")
  "Patterns that disqualify a note from the shared store.

The store is global, so a leak here is permanent and reaches unrelated
work.  The prompt carries the real policy -- general knowledge only, no
project identifiers -- but credentials are objectively detectable and
worth refusing mechanically rather than trusting to judgement."
  :type '(repeat regexp)
  :group 'chat)

(defun chat-knowledge--disqualifying-content (content)
  "Return why CONTENT may not enter the shared store, or nil.

Absolute paths under the home directory are refused because they name
one machine and usually one project, which is the leak this store has to
avoid.  The tilde form is left alone: it is generic."
  (or (cl-find-if (lambda (pattern)
                    (string-match-p pattern content))
                  chat-knowledge-reject-patterns)
      (let ((home (directory-file-name (expand-file-name "~"))))
        (and (string-match-p (regexp-quote home) content)
             (format "an absolute path under %s" home)))))

(defun chat-knowledge-read (name)
  "Return the body of note NAME, or a message explaining why not."
  (let ((path (chat-knowledge-note-path name)))
    (cond
     ((null path) (format "Unusable note name: %s" name))
     ((not (file-exists-p path)) (format "No note named %s." name))
     (t
      (let ((body (with-temp-buffer
                    (insert-file-contents path)
                    (buffer-string))))
        (if (> (length body) chat-knowledge-note-max-chars)
            (concat (substring body 0 chat-knowledge-note-max-chars)
                    "\n...[note truncated]")
          body))))))

(defun chat-knowledge-write (name content &optional mode)
  "Store CONTENT as note NAME.

MODE is \"append\" to add to an existing note, anything else to replace
it.  Appending is offered because a note earns its value by being
corrected and extended, and a run that can only replace will either
clobber what it did not write or start a near-duplicate note."
  (let ((path (chat-knowledge-note-path name)))
    (cond
     ((null path) (format "Unusable note name: %s" name))
     ((or (null content) (string-blank-p content))
      "Refusing to write an empty note.")
     ((chat-knowledge--disqualifying-content content)
      (format (concat "Refusing this note: it contains %s. Shared notes "
                      "are visible in every project, so record the "
                      "general technique with the specifics removed.")
              (chat-knowledge--disqualifying-content content)))
     (t
      (unless (file-directory-p chat-knowledge-directory)
        (make-directory chat-knowledge-directory t))
      (let ((appending (and (equal mode "append") (file-exists-p path))))
        (with-temp-buffer
          (when appending
            (insert-file-contents path)
            (goto-char (point-max))
            (unless (bolp) (insert "\n"))
            (insert "\n"))
          (goto-char (point-max))
          (insert (string-trim-right content) "\n")
          (write-region (point-min) (point-max) path nil 'quiet))
        (format "%s note %s (%s)."
                (if appending "Appended to" "Wrote")
                (file-name-base path)
                path))))))

(defun chat-knowledge-search (text)
  "Return notes whose name, title or body contains TEXT."
  (if (or (null text) (string-blank-p text))
      "Give some text to search for."
    (let (hits)
      (dolist (file (chat-knowledge--notes))
        (with-temp-buffer
          (insert-file-contents file)
          (goto-char (point-min))
          (when (or (string-match-p (regexp-quote text)
                                    (file-name-base file))
                    (search-forward text nil t))
            (push (format "- %s: %s"
                          (file-name-base file)
                          (or (chat-knowledge--title file) ""))
                  hits))))
      (if hits
          (concat "Matching notes:\n" (string-join (nreverse hits) "\n"))
        (format "No note mentions %s." text)))))

;;;###autoload
(defun chat-knowledge-register-tools ()
  "Register the shared knowledge tools."
  (when (fboundp 'chat-tool-forge-register)
    (chat-tool-forge-register
     (make-chat-forged-tool
      :id 'knowledge_read :name "Knowledge Read"
      :description
      (concat "Read one shared knowledge note by name. Names and titles "
              "are listed in the system prompt.")
      :language 'elisp
      :parameters '((:name "name" :type "string" :required t))
      :owner 'knowledge :sensitivity 'project :effects '(read)
      :compiled-function #'chat-knowledge-read
      :is-active t :usage-count 0))
    (chat-tool-forge-register
     (make-chat-forged-tool
      :id 'knowledge_write :name "Knowledge Write"
      :description
      (concat "Write or extend a shared knowledge note. Notes are visible "
              "in every future session across every project, so record "
              "only general, reusable, desensitized knowledge: the "
              "technique rather than the case. No project or repository "
              "names, paths, hostnames, internal identifiers or "
              "credentials. Prefer writing nothing over writing something "
              "that only makes sense here. Use mode \"append\" to extend "
              "an existing note rather than replacing it. Start the "
              "content with a one-line title, which is what the index "
              "shows.")
      :language 'elisp
      :parameters '((:name "name" :type "string" :required t)
                    (:name "content" :type "string" :required t)
                    (:name "mode" :type "string" :required nil))
      :owner 'knowledge :sensitivity 'project :effects '(write)
      :compiled-function #'chat-knowledge-write
      :is-active t :usage-count 0))
    (chat-tool-forge-register
     (make-chat-forged-tool
      :id 'knowledge_search :name "Knowledge Search"
      :description "Find shared knowledge notes mentioning some text."
      :language 'elisp
      :parameters '((:name "text" :type "string" :required t))
      :owner 'knowledge :sensitivity 'project :effects '(read)
      :compiled-function #'chat-knowledge-search
      :is-active t :usage-count 0))))

;;;###autoload
(defun chat-knowledge-open ()
  "Open the shared knowledge directory."
  (interactive)
  (unless (file-directory-p chat-knowledge-directory)
    (make-directory chat-knowledge-directory t))
  (dired chat-knowledge-directory))

(provide 'chat-knowledge)
;;; chat-knowledge.el ends here
