;;; test-docs.el --- the docs name things that exist  -*- lexical-binding: t; -*-

;;; Commentary:

;; A command that gets renamed or removed leaves its old name sitting in
;; the docs, and the docs keep reading as if it still works.  The code
;; cheatsheet named eight `chat-code-quote-*' and `chat-code-ask-*'
;; commands that had moved to `chat-quote-*' and `chat-ask-*' long
;; before, and nothing noticed.  These tests read the docs the way a
;; user would -- take every `M-x' invocation at face value -- and fail
;; when one of them is not a command.

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

(provide 'test-docs)
;;; test-docs.el ends here
