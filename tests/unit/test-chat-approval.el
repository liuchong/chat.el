;;; test-chat-approval.el --- Tests for chat-approval -*- lexical-binding: t -*-
;; Copyright (C) 2026 chat.el contributors
;; Author: chat.el contributors
;; Keywords: tests
;;; Commentary:
;; Unit tests for approval handling.
;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'test-helper)
(require 'chat-session)
(require 'chat-approval)
(require 'chat-files)
(require 'chat-tool-forge)
(require 'chat-tool-shell)
(ert-deftest chat-approval-allows-safe-tool-without-prompt ()
  "Test that safe tools do not prompt for approval."
  (let ((chat-approval-required-tools '(files_write))
        prompted)
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (_prompt)
                 (setq prompted t)
                 t)))
      (should
       (chat-approval-request-tool-call
        (make-chat-forged-tool
         :id 'files_read
         :name "Read File"
         :language 'elisp
         :is-active t)
        '(:name "files_read" :arguments (("path" . "/tmp/demo.txt")))))
      (should-not prompted))))

(ert-deftest chat-approval-requires-metadata-declared-effects-and-sensitivity ()
  "Test permission metadata drives the shared approval gate."
  (let ((chat-approval-required-tools nil))
    (should
     (chat-approval-tool-required-p
      (make-chat-forged-tool
       :id 'write-record
       :sensitivity 'project
       :effects '(write))))
    (should
     (chat-approval-tool-required-p
      (make-chat-forged-tool
       :id 'read-mail
       :sensitivity 'correspondence
       :effects '(read))))
    (should-not
     (chat-approval-tool-required-p
      (make-chat-forged-tool
       :id 'read-project
       :sensitivity 'project
       :effects '(read))))))

(ert-deftest chat-approval-supports-call-specific-predicates ()
  "Test tools can require approval only for sensitive call targets."
  (let ((tool (make-chat-forged-tool
               :id 'dynamic-read
               :sensitivity 'project
               :effects '(read)
               :approval-predicate
               (lambda (call)
                 (equal (cdr (assoc "scope" (plist-get call :arguments)))
                        "personal")))))
    (should-not
     (chat-approval-tool-required-p
      tool '(:arguments (("scope" . "project")))))
    (should
     (chat-approval-tool-required-p
      tool '(:arguments (("scope" . "personal")))))))
(ert-deftest chat-approval-prompts-for-dangerous-tool ()
  "Test that dangerous tools use the decision hook."
  (let ((chat-approval-required-tools '(files_write))
        (chat-approval-noninteractive-policy 'ask)
        (chat-approval-always-approve-tools nil)
        (chat-approval-auto-approve-global nil)
        (chat-approval-decision-function
         (lambda (_tool-id _arguments &optional _session)
           'allow-once)))
    (should (eq (chat-approval--decide
                 'files_write
                 '(("path" . "/tmp/demo.txt")
                   ("content" . "hello world")))
                'allow-once))))

(ert-deftest chat-approval-prompts-for-tool-creation ()
  "Test that forged tool creation also requests approval."
  (let ((chat-approval-tool-creation-required t)
        (chat-approval-noninteractive-policy 'ask)
        captured-prompt)
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (prompt)
                 (setq captured-prompt prompt)
                 t)))
      (should (chat-approval-request-tool-creation
               "Create a tool that lists windows"
               '(:id window-tool :language elisp)))
      (should (string-match-p "window-tool" captured-prompt)))))

(ert-deftest chat-approval-allow-session-grants-only-what-was-approved ()
  "Allowing for the session must not switch the whole session to automatic."
  (chat-test-with-temp-dir
   (chat-test-with-grants
    (let* ((chat-session-directory temp-dir)
           (session (chat-session-create "Approval Session"))
           (chat-approval-required-tools '(files_write shell_execute))
           (chat-approval-noninteractive-policy 'ask)
           (asked 0)
           (chat-approval-decision-function
            (lambda (&rest _args)
              (setq asked (1+ asked))
              'allow-session)))
      (should
       (chat-approval-request-tool-call
        (make-chat-forged-tool
         :id 'shell_execute
         :name "Shell Execute"
         :language 'elisp
         :is-active t)
        '(:name "shell_execute"
          :arguments (("command" . "rg -n Sticker .")))
        session))
      ;; The session is not now approving everything.  It used to be: the
      ;; decision set the session's auto-approve flag, so one yes to one
      ;; command stopped every later tool from asking.
      (should-not (eq (chat-session-auto-approve session) t))
      (should-not (eq (chat-approval-effective-mode session) 'auto))
      ;; The same command needs no second question.
      (should
       (chat-approval-request-tool-call
        (make-chat-forged-tool
         :id 'shell_execute
         :name "Shell Execute"
         :language 'elisp
         :is-active t)
        '(:name "shell_execute"
          :arguments (("command" . "rg -n Sticker .")))
        session))
      (should (= asked 1))
      ;; A different tool in the same session still asks.
      (should
       (chat-approval-request-tool-call
        (make-chat-forged-tool
         :id 'files_write
         :name "Write File"
         :language 'elisp
         :is-active t)
        '(:name "files_write"
          :arguments (("path" . "/tmp/demo.txt")
                      ("content" . "hello world")))
        session))
      (should (= asked 2))))))

(ert-deftest chat-approval-session-grants-do-not-outlive-the-session ()
  "A session grant is not written to the runtime store."
  (chat-test-with-temp-dir
   (chat-test-with-grants
    (let* ((chat-session-directory temp-dir)
           (session (chat-session-create "Approval Session"))
           (chat-approval-required-tools '(shell_execute))
           (chat-approval-noninteractive-policy 'ask)
           (chat-approval-decision-function (lambda (&rest _args) 'allow-session)))
      (chat-approval-request-tool-call
       (make-chat-forged-tool :id 'shell_execute :name "Shell Execute"
                              :language 'elisp :is-active t)
       '(:name "shell_execute" :arguments (("command" . "rg -n Sticker .")))
       session)
      (should (chat-session-approval-grants session))
      (should-not chat-approval--runtime-grants)))))

(ert-deftest chat-approval-allow-tool-records-a-runtime-grant ()
  "Test tool approval choice becomes a runtime grant for that tool."
  (chat-test-with-grants
   (let ((chat-approval-required-tools '(files_write))
         (chat-approval-noninteractive-policy 'ask)
         (chat-approval-always-approve-tools nil)
         (chat-approval-decision-function
          (lambda (&rest _args)
            'allow-tool)))
     (should
      (chat-approval-request-tool-call
       (make-chat-forged-tool
        :id 'files_write
        :name "Write File"
        :language 'elisp
        :is-active t)
       '(:name "files_write"
         :arguments (("path" . "/tmp/demo.txt")
                     ("content" . "hello world")))))
     (let ((grant (car chat-approval--runtime-grants)))
       (should (eq (chat-approval-grant-tool grant) 'files_write))
       (should (eq (chat-approval-grant-scope grant) 'tool))
       (should (eq (chat-approval-grant-source grant) 'runtime))
       (should (chat-approval-grant-created-at grant)))
     ;; The user's own list is untouched.
     (should-not chat-approval-always-approve-tools))))

(ert-deftest chat-approval-allow-command-leaves-the-user-list-alone ()
  "Test shell approval records a runtime grant, not a customisation change."
  (chat-test-with-grants
   (let ((chat-approval-required-tools '(shell_execute))
         (chat-approval-noninteractive-policy 'ask)
         (chat-tool-shell-whitelist nil)
         (chat-approval-decision-function
          (lambda (&rest _args)
            'allow-command)))
     (should
      (chat-approval-request-tool-call
       (make-chat-forged-tool
        :id 'shell_execute
        :name "Shell Execute"
        :language 'elisp
        :is-active t)
       '(:name "shell_execute"
         :arguments (("command" . "rg -n StickerManager .")))))
     (let ((grant (car chat-approval--runtime-grants)))
       (should (equal (chat-approval-grant-pattern grant)
                      "rg -n StickerManager ."))
       (should (eq (chat-approval-grant-scope grant) 'command)))
     (should-not chat-tool-shell-whitelist))))

(ert-deftest chat-approval-allow-directory-records-a-runtime-grant ()
  "Test directory approval choice becomes a runtime grant for that root."
  (chat-test-with-temp-dir
   (chat-test-with-grants
    (let* ((target-file (expand-file-name "docs/guide.md" temp-dir))
           (target-dir (chat-approval--normalize-directory
                        (file-name-directory target-file)))
           (chat-approval-required-tools '(files_write))
           (chat-approval-noninteractive-policy 'ask)
           (chat-approval-always-approve-directories nil)
           (chat-approval-decision-function
            (lambda (&rest _args)
              'allow-directory)))
      (should
       (chat-approval-request-tool-call
        (make-chat-forged-tool
         :id 'files_write
         :name "Write File"
         :language 'elisp
         :is-active t)
        `(:name "files_write"
          :arguments (("path" . ,target-file)
                      ("content" . "hello world")))))
      (let ((grant (car chat-approval--runtime-grants)))
        (should (equal (chat-approval-grant-pattern grant) target-dir))
        (should (eq (chat-approval-grant-scope grant) 'directory)))
      (should-not chat-approval-always-approve-directories)))))

(ert-deftest chat-approval-directory-whitelist-auto-approves-future-file-writes ()
  "Test whitelisted directories auto-approve later file writes."
  (chat-test-with-temp-dir
   (chat-test-with-grants
    (let* ((target-file (expand-file-name "docs/guide.md" temp-dir))
           (target-dir (chat-approval--normalize-directory
                        (file-name-directory target-file)))
           (chat-approval-required-tools '(files_write))
           (chat-approval-always-approve-directories (list target-dir))
           events
           prompted
           (chat-approval-decision-function
            (lambda (&rest _args)
              (setq prompted t)
              'deny)))
      (should
       (chat-approval-request-tool-call
        (make-chat-forged-tool
         :id 'files_write
         :name "Write File"
         :language 'elisp
         :is-active t)
        `(:name "files_write"
          :arguments (("path" . ,target-file)
                      ("content" . "hello world")))
        nil
        (lambda (event)
          (push event events))))
      (should-not prompted)
      (let ((approval (seq-find (lambda (event)
                                  (eq (plist-get event :type) 'approval))
                                events)))
        (should (eq (plist-get approval :decision) 'granted))
        (should (eq (plist-get approval :scope) 'directory))
        (should (eq (plist-get approval :source) 'user))
        (should (equal (plist-get approval :directory) target-dir)))))))

(ert-deftest chat-approval-observer-receives-pending-options-and-command-context ()
  "Test approval observers receive structured pending context."
  (chat-test-with-grants
   (let ((chat-approval-required-tools '(shell_execute))
        (chat-approval-noninteractive-policy 'ask)
        (chat-approval-decision-function
         (lambda (&rest _args)
           'allow-once))
        events)
    (should
     (chat-approval-request-tool-call
      (make-chat-forged-tool
       :id 'shell_execute
       :name "Shell Execute"
       :language 'elisp
       :is-active t)
      '(:name "shell_execute"
        :arguments (("command" . "rg -n StickerManager .")))
      nil
      (lambda (event)
        (push event events))))
    (let ((pending (seq-find (lambda (event)
                               (eq (plist-get event :type) 'approval-pending))
                             events))
          (approval (seq-find (lambda (event)
                                (eq (plist-get event :type) 'approval))
                              events)))
      (should (equal (plist-get pending :tool) "shell_execute"))
      (should (equal (plist-get pending :command) "rg -n StickerManager ."))
      (should (equal (mapcar #'car (plist-get pending :options))
                     '("allow once"
                       "allow for session"
                       "always allow this tool"
                       "always allow this command"
                       "deny")))
      (should (eq (plist-get approval :decision) 'allow-once))
      (should (equal (plist-get approval :command) "rg -n StickerManager ."))))))

(ert-deftest chat-approval-observer-includes-directory-scope-for-file-writes ()
  "Test approval observers receive directory context for file-write tools."
  (chat-test-with-temp-dir
   (chat-test-with-grants
   (let* ((target-file (expand-file-name "docs/guide.md" temp-dir))
          (target-dir (chat-approval--normalize-directory
                       (file-name-directory target-file)))
          (chat-approval-required-tools '(files_write))
          (chat-approval-noninteractive-policy 'ask)
          (chat-approval-decision-function
           (lambda (&rest _args)
             'allow-once))
          events)
     (should
      (chat-approval-request-tool-call
       (make-chat-forged-tool
        :id 'files_write
        :name "Write File"
        :language 'elisp
        :is-active t)
       `(:name "files_write"
         :arguments (("path" . ,target-file)
                     ("content" . "hello world")))
       nil
       (lambda (event)
         (push event events))))
     (let ((pending (seq-find (lambda (event)
                                (eq (plist-get event :type) 'approval-pending))
                              events)))
       (should (equal (plist-get pending :directory) target-dir))
       (should (member "C-c C-f directory" (plist-get pending :actions)))
       (should (equal (mapcar #'car (plist-get pending :options))
                      `("allow once"
                        "allow for session"
                        "always allow this tool"
                        ,(format "always allow this directory (%s)" target-dir)
                        "deny"))))))))

(ert-deftest chat-approval-allow-command-notifies-whitelist-update ()
  "Test command approval emits a whitelist update event for observers."
  (chat-test-with-grants
   (let ((chat-approval-required-tools '(shell_execute))
        (chat-approval-noninteractive-policy 'ask)
        (chat-tool-shell-whitelist nil)
        (chat-approval-decision-function
         (lambda (&rest _args)
           'allow-command))
        events)
    (should
     (chat-approval-request-tool-call
      (make-chat-forged-tool
       :id 'shell_execute
       :name "Shell Execute"
       :language 'elisp
       :is-active t)
      '(:name "shell_execute"
        :arguments (("command" . "rg -n StickerManager .")))
      nil
      (lambda (event)
        (push event events))))
    (let ((whitelist (seq-find (lambda (event)
                                 (eq (plist-get event :type) 'whitelist-update))
                               events)))
      (should (equal (plist-get whitelist :scope) 'command))
      (should (equal (plist-get whitelist :pattern) "rg -n StickerManager ."))
      (should (equal (plist-get whitelist :tool) "shell_execute"))))))

(ert-deftest chat-approval-allow-directory-notifies-whitelist-update ()
  "Test directory approval emits a whitelist update event for observers."
  (chat-test-with-temp-dir
   (let* ((target-file (expand-file-name "docs/guide.md" temp-dir))
          (target-dir (chat-approval--normalize-directory
                       (file-name-directory target-file)))
          (chat-approval-required-tools '(files_write))
          (chat-approval-noninteractive-policy 'ask)
          (chat-approval-always-approve-directories nil)
          (chat-approval-decision-function
           (lambda (&rest _args)
             'allow-directory))
          events)
     (should
      (chat-approval-request-tool-call
       (make-chat-forged-tool
        :id 'files_write
        :name "Write File"
        :language 'elisp
        :is-active t)
       `(:name "files_write"
         :arguments (("path" . ,target-file)
                     ("content" . "hello world")))
       nil
       (lambda (event)
         (push event events))))
     (let ((whitelist (seq-find (lambda (event)
                                  (eq (plist-get event :type) 'whitelist-update))
                                events)))
       (should (equal (plist-get whitelist :scope) 'directory))
       (should (equal (plist-get whitelist :pattern) target-dir))
       (should (equal (plist-get whitelist :tool) "files_write"))))))

(ert-deftest chat-approval-commands-set-pending-decision ()
  "Test approval commands write the expected pending decision."
  (let ((chat-approval--pending-request '(:tool-id shell_execute))
        (chat-approval--pending-decision nil))
    (cl-letf (((symbol-function 'exit-minibuffer)
               (lambda () t)))
      (chat-approval-allow-session)
      (should (eq chat-approval--pending-decision 'allow-session))
      (setq chat-approval--pending-decision nil)
      (chat-approval-allow-directory)
      (should (eq chat-approval--pending-decision 'allow-directory))
      (setq chat-approval--pending-decision nil)
      (chat-approval-deny)
      (should (eq chat-approval--pending-decision 'deny)))))

(ert-deftest chat-approval-event-context-includes-panel-actions ()
  "Test approval event context carries action hints for the panel."
  (let ((context (chat-approval--event-context
                  'shell_execute
                  '(("command" . "pwd")))))
    (should (equal (plist-get context :command) "pwd"))
    (should (equal (plist-get context :risk) 'high))
    (should (equal (plist-get context :actions)
                   '("C-c C-a once"
                     "C-c C-s session"
                     "C-c C-t tool"
                     "C-c C-c command"
                     "C-c C-d deny")))))

(ert-deftest chat-approval-prompt-includes-shortcut-hints ()
  "Test approval prompts teach the native shortcut flow."
  (let ((prompt (chat-approval--prompt
                 'shell_execute
                 '(("command" . "pwd")))))
    (should (string-match-p "C-c C-a once" prompt))
    (should (string-match-p "C-c C-s session" prompt))
    (should (string-match-p "C-c C-t tool" prompt))
    (should (string-match-p "C-c C-c command" prompt))
    (should (string-match-p "C-c C-d deny" prompt))))

(ert-deftest chat-approval-prompt-includes-directory-shortcut-hint ()
  "Test file-write approval prompts mention the directory shortcut when available."
  (chat-test-with-temp-dir
   (let* ((target-file (expand-file-name "docs/guide.md" temp-dir))
          (prompt (chat-approval--prompt
                   'files_write
                   `(("path" . ,target-file)
                     ("content" . "hi"))
                   (file-name-directory target-file))))
     (should (string-match-p "C-c C-f directory" prompt)))))

(ert-deftest chat-approval-apply-patch-directory-scope-uses-common-ancestor ()
  "Test apply_patch directory scope can whitelist a shared subtree."
  (chat-test-with-temp-dir
   (let* ((patch (string-join
                  '("*** Begin Patch"
                    "*** Update File: docs/a.md"
                    "@@"
                    "-old"
                    "+new"
                    "*** Update File: docs/sub/b.md"
                    "@@"
                    "-old"
                    "+new"
                    "*** End Patch")
                  "\n"))
          (default-directory temp-dir)
          (scope (chat-approval--directory-scope
                  'apply_patch
                  `(("patch" . ,patch)))))
     (should (equal scope
                    (chat-approval--normalize-directory
                     (expand-file-name "docs" temp-dir)))))))

(ert-deftest chat-approval-directory-scope-uses-the-call-session ()
  "A delayed approval event resolves relative paths in its own workspace."
  (chat-test-with-temp-dir
   (let* ((workspace (expand-file-name "workspace/" temp-dir))
          (elsewhere (expand-file-name "elsewhere/" temp-dir))
          (session (make-chat-session :id "approval-workspace")))
     (make-directory workspace t)
     (make-directory elsewhere t)
     (chat-session-set-working-directory session workspace)
     (let ((default-directory elsewhere))
       (should
        (equal
         (chat-approval--directory-scope
          'files_write '(("path" . "src/sample.py")) session)
         (chat-approval--normalize-directory
          (expand-file-name "src/" workspace))))))))
(provide 'test-chat-approval)
;;; test-chat-approval.el ends here
