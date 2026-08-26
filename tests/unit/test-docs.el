;;; test-docs.el --- the docs name things that exist  -*- lexical-binding: t; -*-

;;; Commentary:

;; A command that gets renamed or removed leaves its old name sitting in
;; the docs, and the docs keep reading as if it still works.  The code
;; cheatsheet named eight `chat-code-quote-*' and `chat-code-ask-*'
;; commands that had moved to `chat-quote-*' and `chat-ask-*' long
;; before, and nothing noticed.  These tests read the docs the way a
;; user would -- take every `M-x' invocation at face value -- and fail
;; when one of them is not a command.
;;
;; Docstrings are documentation too, and were left out of that the first
;; time.  When the two surfaces merged, the Markdown was cleaned of `code
;; mode' and the docstrings were not, so `M-x chat-code-start' went on
;; offering to "start a code mode session" for months -- and `M-x' is the
;; one place a docstring is read.  Checking one and not the other is the
;; same blind spot as a one-way consistency test.

;;; Code:

(require 'ert)
(require 'test-helper)
(require 'chat)

(defconst test-docs-files
  '("docs/code-mode-cheatsheet.md"
    "docs/code-mode-usage.md"
    "README.md")
  "Docs read for command names, relative to the project root.")

(defconst test-docs-foreign-commands
  '("lsp" "eglot" "package-install" "package-refresh-contents"
    "customize-group" "customize-variable" "revert-buffer"
    "load-file" "byte-compile-file" "eval-buffer")
  "Commands the docs name that belong to Emacs or another package.

Only the ones this suite does not load; anything shipped here has to
exist.")

(defun test-docs-root ()
  "Return the project root."
  (locate-dominating-file
   (or load-file-name buffer-file-name default-directory) "chat.el"))

(defun test-docs-commands-named-in (file)
  "Return the commands FILE tells the reader to run with \\[execute-extended-command]."
  (let ((path (expand-file-name file (test-docs-root)))
        names)
    (when (file-exists-p path)
      (with-temp-buffer
        (insert-file-contents path)
        (goto-char (point-min))
        (while (re-search-forward "M-x[ \t]+\\([a-zA-Z0-9-]+\\)" nil t)
          ;; A `*' after the name means the doc wrote a family rather
          ;; than a command, as in "the matching M-x chat-ask-* commands".
          (unless (eq (char-after) ?*)
            (push (cons (match-string 1) (line-number-at-pos)) names)))))
    names))

(ert-deftest test-docs-every-command-the-docs-name-exists ()
  "Every `M-x' name in the docs has to be a real command."
  (let ((checked 0)
        (missing nil))
    (dolist (file test-docs-files)
      (dolist (entry (test-docs-commands-named-in file))
        (unless (member (car entry) test-docs-foreign-commands)
          (setq checked (1+ checked))
          (unless (commandp (intern (car entry)))
            (push (format "%s:%d: %s" file (cdr entry) (car entry))
                  missing)))))
    ;; A regexp that stopped matching would pass this test without
    ;; reading anything, so require that it found a real number of names.
    (should (> checked 20))
    (should-not missing)))

(ert-deftest test-docs-do-not-promise-a-separate-code-buffer ()
  "Code capability is a session property, so there is no code buffer.

The docs described a `*chat:code:<session>*' buffer with its own major
mode and its own keymap.  Both are gone; a coding session is an ordinary
chat buffer."
  (let (stale)
    (dolist (file test-docs-files)
      (let ((path (expand-file-name file (test-docs-root))))
        (when (file-exists-p path)
          (with-temp-buffer
            (insert-file-contents path)
            (goto-char (point-min))
            (while (re-search-forward "\\*chat:code:\\|chat-code-mode" nil t)
              (push (format "%s:%d: %s" file (line-number-at-pos)
                            (match-string 0))
                    stale))))))
    (should-not stale)))

(defconst test-docs-dead-terms
  "code mode\\|\\*chat:code:\\|chat-code-mode"
  "Names for things the merge removed.

`code mode' was a major mode, a buffer and a second copy of the request
pipeline.  None of it exists: a coding session is an ordinary chat buffer
whose session carries project context.  The term has to go with it, or
it stays in circulation and gets written into the next thing.")

(defun test-docs-chat-symbols (predicate)
  "Return every `chat-' symbol satisfying PREDICATE."
  (let (found)
    (mapatoms
     (lambda (symbol)
       (when (and (string-prefix-p "chat-" (symbol-name symbol))
                  (funcall predicate symbol))
         (push symbol found))))
    found))

(ert-deftest test-docs-no-command-offers-a-mode-that-was-removed ()
  "A docstring is what `M-x' shows, and it has to describe this program.

This is the direction the doc tests were missing.  The Markdown was
checked and the docstrings were not, so every `chat-code-*' entry point
went on describing itself as starting a mode that had been deleted --
visible in the completion list, which is exactly where someone looking
for the command reads it."
  (let ((commands (test-docs-chat-symbols #'commandp))
        stale)
    ;; A predicate that stopped matching would pass this vacuously.
    (should (> (length commands) 40))
    (dolist (command commands)
      (when-let ((doc (documentation command)))
        (when (string-match-p test-docs-dead-terms doc)
          (push (symbol-name command) stale))))
    (should-not stale)))

(ert-deftest test-docs-no-setting-offers-a-mode-that-was-removed ()
  "Customize shows these, and a stale one describes a program that is not
this one."
  (let ((settings (test-docs-chat-symbols #'custom-variable-p))
        stale)
    (should (> (length settings) 40))
    (dolist (setting settings)
      (when-let ((doc (documentation-property setting 'variable-documentation)))
        (when (string-match-p test-docs-dead-terms doc)
          (push (symbol-name setting) stale))))
    (should-not stale)))

(provide 'test-docs)
;;; test-docs.el ends here
