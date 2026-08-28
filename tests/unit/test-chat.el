;;; test-chat.el --- Tests for main chat.el entry point -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: tests

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Unit tests for chat.el main entry point and configuration.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'test-helper)
(require 'chat)

;; ------------------------------------------------------------------
;; Feature Loading
;; ------------------------------------------------------------------

(ert-deftest chat-feature-is-loaded ()
  "Test that chat feature is properly loaded."
  (should (featurep 'chat)))

;; ------------------------------------------------------------------
;; Configuration Variables
;; ------------------------------------------------------------------

(ert-deftest chat-default-model-is-set ()
  "Test that chat-default-model has a default value."
  (should chat-default-model)
  (should (symbolp chat-default-model))
  (should (eq chat-default-model 'kimi)))

(ert-deftest chat-session-list-page-size-defaults-to-five ()
  "Session pickers start with a small, configurable recent page."
  (should (= (default-value 'chat-session-list-page-size) 5)))

(ert-deftest chat-load-config-files-loads-supported-locations-in-order ()
  "Test config files load from all supported locations in override order."
  (chat-test-with-temp-dir
   (let* ((home-dir temp-dir)
          (root-dir (expand-file-name "repo" temp-dir))
          (chat-dir (expand-file-name ".chat" home-dir))
          (process-environment (cons (format "HOME=%s" home-dir)
                                     process-environment))
          loaded-files)
     (make-directory root-dir t)
     (make-directory chat-dir t)
     (with-temp-file (expand-file-name ".chat.el" home-dir)
       (insert "(setq chat-test-config-order '(global-root))\n"
               "(setq chat-test-config-value 'home)\n"))
     (with-temp-file (expand-file-name "config.el" chat-dir)
       (insert "(setq chat-test-config-order (append chat-test-config-order '(chat-dir)))\n"
               "(setq chat-test-config-value 'chat-dir)\n"))
     (with-temp-file (expand-file-name "chat-config.local.el" root-dir)
       (insert "(setq chat-test-config-order (append chat-test-config-order '(project-local)))\n"
               "(setq chat-test-config-value 'project)\n"))
     (setq chat-test-config-order nil)
     (setq chat-test-config-value nil)
     (unwind-protect
         (progn
           (setq loaded-files (chat-load-config-files root-dir))
           (should (equal (mapcar #'file-name-nondirectory loaded-files)
                          '(".chat.el" "config.el" "chat-config.local.el")))
           (should (equal chat-test-config-order
                          '(global-root chat-dir project-local)))
           (should (eq chat-test-config-value 'project)))
       (makunbound 'chat-test-config-order)
       (makunbound 'chat-test-config-value)))))

(ert-deftest chat-session-directory-configurable ()
  "Test that session directory can be configured."
  (chat-test-with-temp-dir
   (let ((chat-session-directory temp-dir))
     (should (string= chat-session-directory temp-dir))
     (chat-session--ensure-directory)
     (should (file-directory-p temp-dir)))))

;; ------------------------------------------------------------------
;; Main Commands
;; ------------------------------------------------------------------

(ert-deftest chat-command-is-bound ()
  "Test that M-x chat is bound."
  (should (fboundp 'chat))
  (should (commandp 'chat)))

(ert-deftest chat-new-session-command-is-bound ()
  "Test that chat-new-session is bound."
  (should (fboundp 'chat-new-session))
  (should (commandp 'chat-new-session)))

(ert-deftest chat-list-sessions-command-is-bound ()
  "Test that chat-list-sessions is bound."
  (should (fboundp 'chat-list-sessions))
  (should (commandp 'chat-list-sessions)))

(ert-deftest chat-session-picker-reveals-older-sessions-in-pages ()
  "Choosing the more candidate expands the picker without losing recency order."
  (let* ((chat-session-list-page-size 2)
         (sessions
          (mapcar (lambda (number)
                    (make-chat-session
                     :id (format "session-%d" number)
                     :name (format "Session %d" number)
                     :model-id 'kimi))
                  '(1 2 3 4 5)))
         collections
         (answers (list chat--more-sessions-label "Session 3"))
         opened)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt collection &rest _)
                 (push (copy-sequence collection) collections)
                 (pop answers)))
              ((symbol-function 'chat--open-session)
               (lambda (session) (setq opened session))))
      (chat--select-or-create-session sessions))
    (setq collections (nreverse collections))
    (should (equal (car collections)
                   '("Session 1" "Session 2" "More sessions...")))
    (should (equal (cadr collections)
                   '("Session 1" "Session 2" "Session 3" "Session 4"
                     "More sessions...")))
    (should (equal (chat-session-id opened) "session-3"))))

(ert-deftest chat-session-list-buffer-reveals-more-with-a-button ()
  "The list buffer renders one recent page and expands on demand."
  (let* ((chat-session-list-page-size 2)
         (now (current-time))
         (sessions
          (mapcar (lambda (number)
                    (make-chat-session
                     :id (format "session-%d" number)
                     :name (format "Session %d" number)
                     :model-id 'kimi
                     :updated-at now))
                  '(1 2 3 4 5))))
    (unwind-protect
        (cl-letf (((symbol-function 'chat-session-list)
                   (lambda () sessions))
                  ((symbol-function 'pop-to-buffer) #'ignore))
          (chat-list-sessions)
          (with-current-buffer "*Chat Sessions*"
            (should (string-match-p "Showing 2 of 5" (buffer-string)))
            (should (string-match-p "Session 2" (buffer-string)))
            (should-not (string-match-p "Session 3" (buffer-string)))
            (goto-char (point-min))
            (search-forward chat--more-sessions-label)
            (button-activate (button-at (1- (point))))
            (should (string-match-p "Showing 4 of 5" (buffer-string)))
            (should (string-match-p "Session 4" (buffer-string)))
            (should-not (string-match-p "Session 5" (buffer-string)))))
      (when (get-buffer "*Chat Sessions*")
        (kill-buffer "*Chat Sessions*")))))

(ert-deftest chat-show-help-command-is-bound ()
  (should (commandp 'chat-show-help))
  (should (eq (lookup-key chat-mode-map (kbd "C-c C-h")) 'chat-show-help)))

(ert-deftest chat-set-model-command-is-bound ()
  (should (commandp 'chat-set-model))
  (should (eq (lookup-key chat-mode-map (kbd "C-c C-m")) 'chat-set-model)))

(defconst chat-test--help-key-regexp
  "\\bC-c \\(?:C-SPC\\|C-[a-zA-Z]\\|[a-zA-Z]\\)\\(?:\\s-\\|$\\)"
  "Matches a whole prefixed key sequence, not a prefix of one.

`C-c C-SPC' has to be tried before `C-c C-[a-zA-Z]', or the alternation
settles for `C-c C' and reports a key nobody wrote.")

(defconst chat-test--help-standalone-key
  (concat "\\(?:[CMSsH]-\\)*"
          "\\(?:RET\\|TAB\\|SPC\\|DEL\\|ESC\\|<[a-z-]+>\\|[a-zA-Z]\\)")
  "Matches one unprefixed key such as `RET', `C-g' or `M-p'.")

(defconst chat-test--help-standalone-key-regexp
  (concat "^ +\\(" chat-test--help-standalone-key
          "\\(?: */ *" chat-test--help-standalone-key "\\)*"
          "\\)\\s-+- ")
  "Matches the unprefixed keys at the head of a help line.

The help documents `RET', `C-g' and `C-a' this way, and a regexp that
only understood `C-c ...' left every one of them unchecked -- which is
how `C-a' came to be bound without a line naming it.

A line may name a pair, as `M-p / M-n' does.  The prefixed regexp above
reads both halves because it is not anchored; this one is, so it has to
allow the pair explicitly or it sees only the first key and reports the
second as undocumented when the help documents it perfectly well.")

(defun chat-test--help-keys ()
  "Return the key sequences `chat-commands-help' names, normalized."
  (let (keys)
    (with-temp-buffer
      (insert chat-commands-help)
      (goto-char (point-min))
      (while (re-search-forward chat-test--help-key-regexp nil t)
        (push (key-description (kbd (string-trim (match-string 0)))) keys)
        ;; The trailing whitespace may open the next key on a line of
        ;; two, as in "C-c C-n / C-c C-l".
        (goto-char (match-end 0))
        (skip-chars-backward " \t"))
      (goto-char (point-min))
      (while (re-search-forward chat-test--help-standalone-key-regexp nil t)
        (dolist (key (split-string (match-string 1) "/" t "[ \t]+"))
          (push (key-description (kbd key)) keys))))
    (delete-dups keys)))

(defun chat-test--bound-keys ()
  "Return the key sequences bound in `chat-mode-map', normalized."
  (let (keys)
    (map-keymap
     (lambda (event definition)
       (cond
        ((keymapp definition)
         (map-keymap
          (lambda (inner _def)
            (push (key-description (vector event inner)) keys))
          definition))
        (definition
         (push (key-description (vector event)) keys))))
     chat-mode-map)
    keys))

(ert-deftest chat-every-key-the-help-advertises-is-bound ()
  "A key named in the help has to do something when pressed.

Two surfaces each documented `C-c C-a' for a different command; when they
became one keymap, one of the two would have lost silently."
  (let ((documented (chat-test--help-keys))
        (missing nil))
    ;; A regexp that matched nothing would satisfy the loop below without
    ;; checking anything, so pin the extraction to keys known to be
    ;; documented, one of them the awkward shape that reads as a prefix.
    (should (member (key-description (kbd "C-c C-h")) documented))
    (should (member (key-description (kbd "C-c C-SPC")) documented))
    (should (member (key-description (kbd "C-c C-a")) documented))
    (should (> (length documented) 10))
    (dolist (key documented)
      (unless (commandp (lookup-key chat-mode-map (kbd key)))
        (push key missing)))
    (should-not missing)))

(defun chat-test--documented-commands (documented)
  "Return the commands reachable from the DOCUMENTED key sequences."
  (delq nil (mapcar (lambda (key) (lookup-key chat-mode-map (kbd key)))
                    documented)))

(ert-deftest chat-every-bound-key-appears-in-the-help ()
  "A key that only the keymap knows about is a key nobody finds."
  (let* ((documented (chat-test--help-keys))
         (documented-commands (chat-test--documented-commands documented))
         (undocumented nil))
    (dolist (key (chat-test--bound-keys))
      ;; Sending, newline and cancel are part of using the buffer rather
      ;; than commands to look up, and the help covers them in prose.
      (unless (or (member key '("RET" "<return>"))
                  (string-match-p "mouse\\|remap\\|menu" key)
                  (member key documented)
                  ;; A second key for a documented command is findable:
                  ;; `<home>' beside `C-a' needs no line of its own.
                  (memq (lookup-key chat-mode-map (kbd key))
                        documented-commands))
        (push key undocumented)))
    (should-not undocumented)))

(defconst chat-test--unimplemented-slash-commands
  '()
  "Slash names the help promises that no handler answers.

Empty, and meant to stay that way.  It held the five `/wiki-*' names for
as long as they were documented without being wired to anything; they are
now one `/wiki' command with subcommands.  A documented command that does
nothing is a bug report waiting to happen, so either implement it or take
it out of `chat-commands-help' rather than adding it here.")

(defun chat-test--help-slash-names ()
  "Return the slash command names `chat-commands-help' promises."
  (let (names)
    (with-temp-buffer
      (insert chat-commands-help)
      (goto-char (point-min))
      ;; Only at the start of a help line, so prose mentioning a path
      ;; does not read as a command.
      (while (re-search-forward "^ +/\\([a-z?!-]+\\)" nil t)
        (push (match-string 1) names)))
    (delete-dups names)))

(ert-deftest chat-every-slash-command-the-help-promises-is-answered ()
  "A slash command in the help has to reach a handler.

The keymap already has this guarantee; slash commands did not, and the
list of names that answer nothing was buried in a planning note rather
than anywhere a reader would look."
  (let ((promised (chat-test--help-slash-names))
        (unanswered nil))
    ;; A regexp that stopped matching would pass the loop vacuously.
    (should (member "cmd" promised))
    (should (member "auto" promised))
    (should (> (length promised) 8))
    (dolist (name promised)
      (unless (or (chat-ui--command-handler name)
                  (member name chat-test--unimplemented-slash-commands))
        (push name unanswered)))
    (should-not unanswered)))

(ert-deftest chat-the-unimplemented-list-does-not-cover-live-commands ()
  "A name that now works must leave the list, or the list hides a promise."
  (dolist (name chat-test--unimplemented-slash-commands)
    (should-not (chat-ui--command-handler name))))

(defun chat-test--help-mentions-command-p (name)
  "Return non-nil when the help mentions slash command NAME.

Anywhere, not only opening a line: an alias is best documented on the
line of the command it aliases, and pushing each one onto a line of its
own would pad the help to make a test happy."
  (string-match-p (concat "/" (regexp-quote name) "\\(\\b\\|[^a-z-]\\|\\'\\)")
                  chat-commands-help))

(ert-deftest chat-every-live-slash-command-appears-in-the-help ()
  "A command that works and is not documented is a command nobody uses.

This is the direction the slash tests were missing.  The keymap has had
both for a while; slashes only checked that documented names worked, so
`/ask', `/question', `/?' and `/!' all ran and none of them were written
down anywhere -- which is part of how the first two survived long enough
to become confusing.  A one-way consistency test is a blind spot with a
passing badge on it."
  (let (undocumented)
    (dolist (entry chat-ui--command-table)
      (let ((name (plist-get entry :name)))
        (unless (chat-test--help-mentions-command-p name)
          (push name undocumented))))
    (should-not undocumented)))

(ert-deftest chat-the-help-names-both-ways-of-asking ()
  "The difference between them is the thing a reader most needs told."
  (should (string-match-p "/send" chat-commands-help))
  (should (string-match-p "/quick" chat-commands-help))
  ;; And says what separates them, not just that both exist.
  (should (string-match-p "recorded\\|written down" chat-commands-help)))

(ert-deftest chat-accepting-an-edit-and-approving-tools-are-different-keys ()
  "The one collision the merge had to resolve, held in place."
  (let ((accept (lookup-key chat-mode-map (kbd "C-c C-a")))
        (approve (lookup-key chat-mode-map (kbd "C-c C-t"))))
    (should (commandp accept))
    (should (commandp approve))
    (should-not (eq accept approve))))

(ert-deftest chat-code-capabilities-are-reachable-from-the-chat-keymap ()
  "Code capability has no keymap of its own to fall back on."
  (dolist (command '(chat-code-accept-last-edit
                     chat-code-reject-last-edit
                     chat-code-focus-file
                     chat-code-refresh-context))
    (should (commandp command))
    (should (where-is-internal command chat-mode-map))))

(ert-deftest chat-reading-commands-are-bound ()
  (should (commandp 'chat-quote-region))
  (should (commandp 'chat-ask-region))
  (should (commandp 'chat-quote-defun))
  (should (commandp 'chat-ask-defun))
  (should (commandp 'chat-quote-near-point))
  (should (commandp 'chat-ask-near-point))
  (should (commandp 'chat-quote-current-file))
  (should (commandp 'chat-ask-current-file)))

(ert-deftest chat-show-help-renders-reading-workflow-section ()
  (chat-show-help)
  (with-current-buffer "*Chat Help*"
    (should (string-match-p "Reading Workflow:" (buffer-string)))
    (should (string-match-p "chat-quote-region" (buffer-string)))
    (should (string-match-p "chat-ask-current-file" (buffer-string)))))

(ert-deftest chat-show-help-enables-view-mode ()
  (chat-show-help)
  (with-current-buffer "*Chat Help*"
    (should view-mode)))

(ert-deftest chat-buffer-name-uses-session-name ()
  (let ((session (make-chat-session :name "Demo Session")))
    (should (string= (chat--buffer-name session) "*chat:Demo Session*"))))

(ert-deftest chat-reading-session-name-prefers-file-name ()
  (should (string= (chat--reading-session-name "/tmp/demo.el") "Read: demo.el")))

(ert-deftest chat-reading-session-name-falls-back-to-directory-name ()
  (let ((default-directory "/tmp/worktree/"))
    (should (string= (chat--reading-session-name nil) "Read: worktree"))))

(ert-deftest chat-reading-session-name-falls-back-to-root-directory-marker ()
  (let ((default-directory "/"))
    (should (string= (chat--reading-session-name nil) "Read: /"))))

(ert-deftest chat-resolve-last-session-returns-nil-when-missing ()
  (let ((chat--last-session-id "missing"))
    (should-not (chat--resolve-last-session))))

(ert-deftest chat-resolve-last-session-loads-existing-session ()
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-session-create "Existing" 'kimi))
          (chat--last-session-id (chat-session-id session)))
     (let ((resolved (chat--resolve-last-session)))
       (should (string= (chat-session-id resolved) (chat-session-id session)))
       (should (string= (chat-session-name resolved) "Existing"))))))

(ert-deftest chat-ensure-reading-session-prefers-current-chat-session ()
  (chat-test-with-temp-dir
   (let ((chat-session-directory temp-dir)
         (chat--last-session-id nil))
     (with-temp-buffer
       (chat-mode)
       (let ((session (chat-session-create "Current" 'kimi)))
         (setq-local chat--current-session session)
         (should (eq (chat--ensure-reading-session "/tmp/demo.el") session)))))))

(ert-deftest chat-ensure-reading-session-creates-new-session-when-none ()
  (chat-test-with-temp-dir
   (let ((chat-session-directory temp-dir)
         (chat--last-session-id nil))
     (with-temp-buffer
       (let ((session (chat--ensure-reading-session "/tmp/demo.el")))
         (should (string= (chat-session-name session) "Read: demo.el"))
         (should (eq (chat-session-model-id session) chat-default-model)))))))

(ert-deftest chat-ensure-reading-session-reuses-last-session ()
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-session-create "Existing" 'kimi)))
     (setq chat--last-session-id (chat-session-id session))
     (with-temp-buffer
       (let ((resolved (chat--ensure-reading-session "/tmp/other.el")))
         (should (string= (chat-session-id resolved)
                          (chat-session-id session))))))))

(ert-deftest chat-ensure-reading-session-prefers-current-session-over-last-session ()
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (last-session (chat-session-create "Last" 'kimi)))
     (setq chat--last-session-id (chat-session-id last-session))
     (with-temp-buffer
       (chat-mode)
       (let ((current-session (chat-session-create "Current" 'kimi)))
         (setq-local chat--current-session current-session)
         (should (eq (chat--ensure-reading-session "/tmp/demo.el")
                     current-session)))))))

(ert-deftest chat-quote-region-opens-chat-and-inserts-structured-reference ()
  (chat-test-with-temp-dir
   (let ((chat-session-directory temp-dir)
         (chat--last-session-id nil)
         (source-file (expand-file-name "demo.el" temp-dir)))
     (with-temp-file source-file
       (insert "(defun demo ()\n  (message \"hi\"))\n"))
     (with-current-buffer (find-file-noselect source-file)
       (unwind-protect
           (progn
             (goto-char (point-min))
             (search-forward "message")
             (set-mark (line-beginning-position))
             (goto-char (line-end-position))
             (activate-mark)
             (chat-quote-region)
             (with-current-buffer "*chat:Read: demo.el*"
               (let ((quoted (buffer-substring-no-properties
                              (marker-position chat-ui--input-overlay)
                              (point-max))))
                 (should (string-match-p "Question about this code:" quoted))
                 (should (string-match-p "Kind: region" quoted))
                 (should (string-match-p "message" quoted)))))
         (kill-buffer (current-buffer)))))))

(ert-deftest chat-ask-current-file-sends-structured-reference ()
  (chat-test-with-temp-dir
   (let ((chat-session-directory temp-dir)
         (chat--last-session-id nil)
         (source-file (expand-file-name "demo.el" temp-dir))
         sent-content)
     (with-temp-file source-file
       (insert "(defun demo ()\n  (message \"hi\"))\n"))
     (with-current-buffer (find-file-noselect source-file)
       (unwind-protect
           (progn
             (cl-letf (((symbol-function 'chat-ui-send-message)
                        (lambda ()
                          (setq sent-content
                                (buffer-substring-no-properties
                                 (marker-position chat-ui--input-overlay)
                                 (point-max))))))
               (chat-ask-current-file "What matters here?"))
             (should (string-match-p "Question about this code:" sent-content))
             (should (string-match-p "Kind: current-file" sent-content))
             (should (string-match-p "What matters here\\?" sent-content))
             (should (string-match-p "defun demo" sent-content)))
         (kill-buffer (current-buffer)))))))

(ert-deftest chat-quote-region-propagates-missing-region-error ()
  (chat-test-with-temp-dir
   (let ((chat-session-directory temp-dir)
         (source-file (expand-file-name "demo.el" temp-dir)))
     (with-temp-file source-file
       (insert "(message \"hi\")\n"))
     (with-current-buffer (find-file-noselect source-file)
       (unwind-protect
           (should-error (chat-quote-region) :type 'user-error)
         (kill-buffer (current-buffer)))))))

(ert-deftest chat-ask-current-file-propagates-oversized-file-error ()
  (chat-test-with-temp-dir
   (let ((chat-session-directory temp-dir)
         (chat-reading-current-file-max-lines 2)
         (source-file (expand-file-name "demo.el" temp-dir)))
     (with-temp-file source-file
       (insert "line1\nline2\nline3\n"))
     (with-current-buffer (find-file-noselect source-file)
       (unwind-protect
           (should-error (chat-ask-current-file "Too big?") :type 'user-error)
         (kill-buffer (current-buffer)))))))

(ert-deftest chat-quote-current-file-propagates-non-file-buffer-error ()
  (with-temp-buffer
    (should-error (chat-quote-current-file) :type 'user-error)))

(ert-deftest chat-quote-defun-opens-chat-and-inserts-structured-reference ()
  (chat-test-with-temp-dir
   (let ((chat-session-directory temp-dir)
         (chat--last-session-id nil)
         (source-file (expand-file-name "demo.el" temp-dir)))
     (with-temp-file source-file
       (insert "(defun alpha ()\n  (message \"a\"))\n\n(defun beta ()\n  (message \"b\"))\n"))
     (with-current-buffer (find-file-noselect source-file)
       (unwind-protect
           (progn
             (goto-char (point-min))
             (search-forward "message \"b\"")
             (chat-quote-defun)
             (with-current-buffer "*chat:Read: demo.el*"
               (let ((quoted (buffer-substring-no-properties
                              (marker-position chat-ui--input-overlay)
                              (point-max))))
                 (should (string-match-p "Kind: defun" quoted))
                 (should (string-match-p "defun beta" quoted))
                 (should-not (string-match-p "defun alpha" quoted)))))
         (kill-buffer (current-buffer)))))))

(ert-deftest chat-ask-defun-sends-structured-reference ()
  (chat-test-with-temp-dir
   (let ((chat-session-directory temp-dir)
         (chat--last-session-id nil)
         (source-file (expand-file-name "demo.el" temp-dir))
         sent-content)
     (with-temp-file source-file
       (insert "(defun alpha ()\n  (message \"a\"))\n\n(defun beta ()\n  (message \"b\"))\n"))
     (with-current-buffer (find-file-noselect source-file)
       (unwind-protect
           (progn
             (goto-char (point-min))
             (search-forward "message \"b\"")
             (cl-letf (((symbol-function 'chat-ui-send-message)
                        (lambda ()
                          (setq sent-content
                                (buffer-substring-no-properties
                                 (marker-position chat-ui--input-overlay)
                                 (point-max))))))
               (chat-ask-defun "Why beta?"))
             (should (string-match-p "Kind: defun" sent-content))
             (should (string-match-p "Why beta\\?" sent-content))
             (should (string-match-p "defun beta" sent-content)))
         (kill-buffer (current-buffer)))))))

(ert-deftest chat-quote-near-point-opens-chat-and-inserts-structured-reference ()
  (chat-test-with-temp-dir
   (let ((chat-session-directory temp-dir)
         (chat--last-session-id nil)
         (source-file (expand-file-name "demo.el" temp-dir)))
     (with-temp-file source-file
       (insert "line1\nline2\nline3\nline4\nline5\n"))
     (with-current-buffer (find-file-noselect source-file)
       (unwind-protect
           (progn
             (goto-char (point-min))
             (forward-line 2)
             (chat-quote-near-point)
             (with-current-buffer "*chat:Read: demo.el*"
               (let ((quoted (buffer-substring-no-properties
                              (marker-position chat-ui--input-overlay)
                              (point-max))))
                 (should (string-match-p "Kind: near-point" quoted))
                 (should (string-match-p "line3" quoted)))))
         (kill-buffer (current-buffer)))))))

(ert-deftest chat-ask-near-point-sends-structured-reference ()
  (chat-test-with-temp-dir
   (let ((chat-session-directory temp-dir)
         (chat--last-session-id nil)
         (source-file (expand-file-name "demo.el" temp-dir))
         sent-content)
     (with-temp-file source-file
       (insert "line1\nline2\nline3\nline4\nline5\n"))
     (with-current-buffer (find-file-noselect source-file)
       (unwind-protect
           (progn
             (goto-char (point-min))
             (forward-line 2)
             (cl-letf (((symbol-function 'chat-ui-send-message)
                        (lambda ()
                          (setq sent-content
                                (buffer-substring-no-properties
                                 (marker-position chat-ui--input-overlay)
                                 (point-max))))))
               (chat-ask-near-point "What is nearby?"))
             (should (string-match-p "Kind: near-point" sent-content))
             (should (string-match-p "What is nearby\\?" sent-content)))
         (kill-buffer (current-buffer)))))))

(ert-deftest chat-quote-current-file-opens-chat-and-inserts-structured-reference ()
  (chat-test-with-temp-dir
   (let ((chat-session-directory temp-dir)
         (chat--last-session-id nil)
         (source-file (expand-file-name "demo.el" temp-dir)))
     (with-temp-file source-file
       (insert "(defun demo ()\n  (message \"hi\"))\n"))
     (with-current-buffer (find-file-noselect source-file)
       (unwind-protect
           (progn
             (chat-quote-current-file)
             (with-current-buffer "*chat:Read: demo.el*"
               (let ((quoted (buffer-substring-no-properties
                              (marker-position chat-ui--input-overlay)
                              (point-max))))
                 (should (string-match-p "Kind: current-file" quoted))
                 (should (string-match-p "defun demo" quoted)))))
         (kill-buffer (current-buffer)))))))

(ert-deftest chat-quote-current-file-replaces-existing-input-in-reused-session ()
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (existing (chat-session-create "Existing" 'kimi))
          (chat--last-session-id (chat-session-id existing))
          (source-file (expand-file-name "demo.el" temp-dir)))
     (with-temp-file source-file
       (insert "(defun demo ()\n  (message \"hi\"))\n"))
     (chat--open-session existing)
     (with-current-buffer "*chat:Existing*"
       (goto-char (marker-position chat-ui--input-overlay))
       (insert "stale input"))
     (with-current-buffer (find-file-noselect source-file)
       (unwind-protect
           (progn
             (chat-quote-current-file)
             (with-current-buffer "*chat:Existing*"
               (let ((quoted (buffer-substring-no-properties
                              (marker-position chat-ui--input-overlay)
                              (point-max))))
                 (should-not (string-match-p "stale input" quoted))
                 (should (string-match-p "Kind: current-file" quoted)))))
         (kill-buffer (current-buffer)))))))

(ert-deftest chat-ask-region-sends-structured-reference ()
  (chat-test-with-temp-dir
   (let ((chat-session-directory temp-dir)
         (chat--last-session-id nil)
         (source-file (expand-file-name "demo.el" temp-dir))
         sent-content)
     (with-temp-file source-file
       (insert "(defun demo ()\n  (message \"hi\"))\n"))
     (with-current-buffer (find-file-noselect source-file)
       (unwind-protect
           (progn
             (goto-char (point-min))
             (search-forward "message")
             (set-mark (line-beginning-position))
             (goto-char (line-end-position))
             (activate-mark)
             (cl-letf (((symbol-function 'chat-ui-send-message)
                        (lambda ()
                          (setq sent-content
                                (buffer-substring-no-properties
                                 (marker-position chat-ui--input-overlay)
                                 (point-max))))))
               (chat-ask-region "Why is this here?"))
             (should (string-match-p "Kind: region" sent-content))
             (should (string-match-p "Why is this here\\?" sent-content)))
         (kill-buffer (current-buffer)))))))

(ert-deftest chat-ask-current-file-replaces-existing-input-before-send ()
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (existing (chat-session-create "Existing" 'kimi))
          (chat--last-session-id (chat-session-id existing))
          (source-file (expand-file-name "demo.el" temp-dir))
          sent-content)
     (with-temp-file source-file
       (insert "(defun demo ()\n  (message \"hi\"))\n"))
     (chat--open-session existing)
     (with-current-buffer "*chat:Existing*"
       (goto-char (marker-position chat-ui--input-overlay))
       (insert "stale input"))
     (with-current-buffer (find-file-noselect source-file)
       (unwind-protect
           (progn
             (cl-letf (((symbol-function 'chat-ui-send-message)
                        (lambda ()
                          (setq sent-content
                                (buffer-substring-no-properties
                                 (marker-position chat-ui--input-overlay)
                                 (point-max))))))
               (chat-ask-current-file "What matters here?"))
             (should-not (string-match-p "stale input" sent-content))
             (should (string-match-p "What matters here\\?" sent-content)))
         (kill-buffer (current-buffer)))))))

(ert-deftest chat-reading-command-reuses-existing-session-buffer ()
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (existing (chat-session-create "Existing" 'kimi))
          (chat--last-session-id (chat-session-id existing))
          (source-file (expand-file-name "demo.el" temp-dir)))
     (with-temp-file source-file
       (insert "(defun demo ()\n  (message \"hi\"))\n"))
     (chat--open-session existing)
     (with-current-buffer (find-file-noselect source-file)
       (unwind-protect
           (progn
             (chat-quote-current-file)
             (should (get-buffer "*chat:Existing*"))
             (with-current-buffer "*chat:Existing*"
               (let ((quoted (buffer-substring-no-properties
                              (marker-position chat-ui--input-overlay)
                              (point-max))))
             (should (string-match-p "Kind: current-file" quoted)))))
         (kill-buffer (current-buffer)))))))

(ert-deftest chat-reading-command-updates-last-session-id ()
  (chat-test-with-temp-dir
   (let ((chat-session-directory temp-dir)
         (chat--last-session-id nil)
         (source-file (expand-file-name "demo.el" temp-dir)))
     (with-temp-file source-file
       (insert "(defun demo ()\n  (message \"hi\"))\n"))
     (with-current-buffer (find-file-noselect source-file)
       (unwind-protect
           (progn
             (chat-quote-current-file)
             (with-current-buffer "*chat:Read: demo.el*"
               (should (string=
                        chat--last-session-id
                        (chat-session-id chat--current-session)))))
         (kill-buffer (current-buffer)))))))

(ert-deftest chat-quote-current-file-propagates-oversized-file-error ()
  (chat-test-with-temp-dir
   (let ((chat-session-directory temp-dir)
         (chat--last-session-id nil)
         (chat-reading-current-file-max-lines 1)
         (source-file (expand-file-name "demo.el" temp-dir)))
     (with-temp-file source-file
       (insert "line1\nline2\n"))
     (with-current-buffer (find-file-noselect source-file)
       (unwind-protect
           (should-error (chat-quote-current-file) :type 'user-error)
         (kill-buffer (current-buffer)))))))

;; ------------------------------------------------------------------
;; Utility Functions
;; ------------------------------------------------------------------

(ert-deftest chat-version-returns-string ()
  "Test that chat-version returns version string."
  (let ((version (chat-version)))
    (should (stringp version))
    (should (> (length version) 0))))

(ert-deftest chat-registers-core-file-tools ()
  "Test that loading chat registers built in file tools."
  (should (chat-tool-forge-get 'files_read))
  (should (chat-tool-forge-get 'files_patch))
  (should (chat-tool-forge-get 'apply_patch))
  (should (chat-tool-forge-get 'files_write)))

(provide 'test-chat)
;;; test-chat.el ends here
