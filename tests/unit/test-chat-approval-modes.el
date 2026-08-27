;;; test-chat-approval-modes.el --- Tests for approval modes and grants -*- lexical-binding: t -*-
;; Copyright (C) 2026 chat.el contributors
;; Author: chat.el contributors
;; Keywords: tests
;;; Commentary:
;; Covers specs/012-approval-modes-and-grants.md: the three modes, the four
;; grant sources, and the one question the command gate left open -- whether
;; a person who approved a command gets to have approved it.
;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'test-helper)
(require 'chat-session)
(require 'chat-approval-grants)
(require 'chat-approval)
(require 'chat-files)
(require 'chat-tool-forge)
(require 'chat-tool-shell)
(require 'chat-work)
(require 'chat-subagent)
(require 'chat-ui)

(defun test-chat-approval-tool (id &optional effects)
  "Return a forged tool named ID with EFFECTS for approval tests."
  (make-chat-forged-tool
   :id id
   :name (symbol-name id)
   :language 'elisp
   :is-active t
   :effects (or effects '(write))))

;;; The three modes

(ert-deftest chat-approval-mode-defaults-to-manual ()
  "The default has to be the mode where a refusal can be appealed."
  (should (eq chat-approval-mode 'manual))
  (should (eq (chat-approval-effective-mode nil) 'manual)))

(ert-deftest chat-approval-a-session-may-override-the-global-mode ()
  "A session says which mode it is in; `inherit' means it does not."
  (let ((chat-approval-mode 'manual)
        (session (make-chat-session :id "s" :name "S")))
    (setf (chat-session-approval-mode session) 'inherit)
    (should (eq (chat-approval-effective-mode session) 'manual))
    (setf (chat-session-approval-mode session) 'guarded)
    (should (eq (chat-approval-effective-mode session) 'guarded))
    (let ((chat-approval-mode 'dangerous))
      (should (eq (chat-approval-effective-mode session) 'guarded)))))

(ert-deftest chat-approval-the-old-auto-name-still-reads-as-guarded ()
  "`auto' has to be accepted on the way in, and never written back out.

Sessions on disk carry `approvalMode: \"auto\"'.  Dropping the name would
read them as the default and quietly change what those sessions may do,
which is the same failure as ignoring `autoApprove'."
  (should (eq (chat-approval-normalize-mode 'auto) 'guarded))
  (should (eq (chat-approval-normalize-mode "auto") 'guarded))
  (should (eq (chat-approval-normalize-mode 'guarded) 'guarded))
  (should-not (chat-approval-normalize-mode 'nonsense))
  (should-not (memq 'auto chat-approval-modes))
  (let ((chat-approval-mode 'manual)
        (session (make-chat-session :id "s" :name "S")))
    (setf (chat-session-approval-mode session) 'auto)
    (should (eq (chat-approval-effective-mode session) 'guarded))
    ;; Read as an alias, written as the current name.
    (should (equal (chat-session--approval-mode-wire session) "guarded")))
  (should (eq (chat-session--approval-mode-from-wire "auto" nil) 'guarded))
  ;; A global set to the old name behaves as the new one too, because user
  ;; configuration outlives a rename just as session files do.
  (let ((chat-approval-mode 'auto))
    (should (eq (chat-approval-effective-mode nil) 'guarded))))

(ert-deftest chat-approval-an-old-session-with-auto-approve-reads-as-guarded ()
  "Sessions on disk carry `autoApprove'; it must not read as the default.

A session saved with the flag set was running with approval off.  Reading
it as `manual' would start asking in a session someone left unattended,
and reading it as `dangerous' would hand out the one mode that has to be
chosen on purpose."
  (let ((chat-approval-mode 'manual)
        (session (make-chat-session :id "s" :name "S" :auto-approve t)))
    (should (eq (chat-approval-effective-mode session) 'guarded))
    (should (eq (chat-session--approval-mode-from-wire nil t) 'guarded))
    (should (eq (chat-session--approval-mode-from-wire nil :json-false)
                'inherit))
    (should (eq (chat-session--approval-mode-from-wire "dangerous" nil)
                'dangerous))))

(ert-deftest chat-approval-an-old-auto-approve-session-goes-through-the-rules ()
  "The mode has to be the only route, or it is decoration.

Reading `autoApprove' as `guarded' is not enough on its own: while the flag
also had its own branch in the decision, such a session approved
everything without consulting a rule, and the mode it reported was not the
mode it behaved as."
  (chat-test-with-grants
   (let ((chat-approval-mode 'manual)
         (chat-approval-required-tools '(shell_execute))
         (session (make-chat-session :id "s" :name "S" :auto-approve t))
         (chat-approval-decision-function
          (lambda (&rest _args)
            (ert-fail "a guarded session must not ask"))))
     (should (eq (chat-approval-effective-mode session) 'guarded))
     ;; Allowed by the gate, so the rules let it through.
     (should (chat-approval-authorize
              (test-chat-approval-tool 'shell_execute)
              '(:name "shell_execute" :arguments (("command" . "cat /etc/hosts")))
              session))
     ;; Refused by the gate, so the rules refuse it -- it does not sail
     ;; through on the strength of the flag.
     (should-not (chat-approval-authorize
                  (test-chat-approval-tool 'shell_execute)
                  '(:name "shell_execute"
                    :arguments (("command" . "git push origin main")))
                  session)))))

(ert-deftest chat-approval-dangerous-mode-runs-what-the-gate-would-refuse ()
  "Allow everything has to mean the gate too, or it means nothing."
  (chat-test-with-grants
   (let ((chat-approval-mode 'dangerous)
         (chat-tool-shell-enabled t)
         events)
     (should (eq (chat-approval-authorize
                  (test-chat-approval-tool 'shell_execute)
                  '(:name "shell_execute"
                    :arguments (("command" . "echo one | tr a-z A-Z")))
                  nil
                  (lambda (event) (push event events)))
                 'dangerous))
     (let ((approval (seq-find (lambda (event)
                                 (eq (plist-get event :type) 'approval))
                               events)))
       (should (eq (plist-get approval :decision) 'dangerous-mode)))
     ;; And the tool itself runs it: a pipe is refused by the gate, so this
     ;; only works because consent reaches the tool.
     (let ((chat-approval-consent 'dangerous))
       (should (string-match-p
                "ONE"
                (chat-tool-shell-execute "echo one | tr a-z A-Z")))))))

(ert-deftest chat-approval-dangerous-mode-still-obeys-the-path-boundary ()
  "Dangerous mode means stop asking, not forget the configured limits."
  (chat-test-with-temp-dir
   (let ((chat-approval-mode 'dangerous)
         (chat-files-allowed-directories (list temp-dir))
         (chat-approval-consent 'dangerous))
     (should-error (chat-files-write "/etc/chat-el-should-not-write" "nope"))
     (should-not (file-exists-p "/etc/chat-el-should-not-write")))))

(ert-deftest chat-approval-guarded-without-a-guard-follows-the-gate-and-never-asks ()
  "With no guard configured the fallback rules decide, and they never ask.

This is the degraded path, not the mode's intent: `guarded' means a guard
model rules on the call.  Nothing is configured here, so the fallback runs
and its verdict is the gate's."
  (chat-test-with-grants
   (let ((chat-approval-mode 'guarded)
         (chat-approval-decision-function
          (lambda (&rest _args) (ert-fail "guarded mode must not ask")))
         events)
     ;; `cat' passes the gate and is on no whitelist, so the rules are what
     ;; decided here rather than a grant.
     (should (eq (chat-approval-authorize
                  (test-chat-approval-tool 'shell_execute)
                  '(:name "shell_execute"
                    :arguments (("command" . "cat /etc/hosts")))
                  nil
                  (lambda (event) (push event events)))
                 'rule))
     ;; A writing one does not, and the refusal says which token failed.
     (setq events nil)
     (should-not (chat-approval-authorize
                  (test-chat-approval-tool 'shell_execute)
                  '(:name "shell_execute"
                    :arguments (("command" . "git push origin main")))
                  nil
                  (lambda (event) (push event events))))
     (let ((approval (seq-find (lambda (event)
                                 (eq (plist-get event :type) 'approval))
                               events)))
       (should-not (plist-get approval :approved))
       (should (string-match-p "push" (plist-get approval :reason)))
       ;; The fallback has to say it is the fallback.  A mode that silently
       ;; behaves as a worse mode is the failure this flag exists to
       ;; prevent.
       (should (plist-get approval :degraded))
       (should (eq (plist-get approval :decision) 'guarded-fallback))))))

(ert-deftest chat-approval-guarded-fallback-allows-a-read-only-tool ()
  "Reading needs nobody's permission."
  (chat-test-with-grants
   (let ((chat-approval-mode 'guarded)
         (chat-approval-required-tools '(inspect_thing))
         (chat-approval-decision-function
          (lambda (&rest _args) (ert-fail "guarded mode must not ask"))))
     (should (eq (chat-approval-authorize
                  (test-chat-approval-tool 'inspect_thing '(read))
                  '(:name "inspect_thing" :arguments nil))
                 'rule)))))

(ert-deftest chat-approval-guarded-fallback-denies-an-unexamined-write ()
  "With nobody watching, a write no rule allowed does not happen."
  (chat-test-with-grants
   (let ((chat-approval-mode 'guarded)
         (chat-approval-required-tools '(publish_thing))
         (chat-approval-decision-function
          (lambda (&rest _args) (ert-fail "guarded mode must not ask"))))
     (should-not (chat-approval-authorize
                  (test-chat-approval-tool 'publish_thing '(outbound))
                  '(:name "publish_thing" :arguments nil))))))

(ert-deftest chat-approval-manual-mode-asks-and-says-why-the-rules-object ()
  "The gate's reason belongs in the question, not instead of it."
  (chat-test-with-grants
   (let* ((chat-approval-mode 'manual)
          (chat-approval-required-tools '(shell_execute))
          (chat-approval-noninteractive-policy 'ask)
          (asked-prompt nil)
          (chat-approval-decision-function
           (lambda (tool-id arguments &optional _session)
             (setq asked-prompt (chat-approval--prompt tool-id arguments))
             'allow-once)))
     (should (eq (chat-approval-authorize
                  (test-chat-approval-tool 'shell_execute)
                  '(:name "shell_execute"
                    :arguments (("command" . "git push origin main"))))
                 'human))
     (should (string-match-p "Outside the rules" asked-prompt))
     (should (string-match-p "push" asked-prompt)))))

(ert-deftest chat-approval-a-person-who-approves-a-command-has-approved-it ()
  "The whole point: `make test' approved by a person actually runs.

Before this, approval ran first and the gate second, with no way for one
to inform the other, so a user could read the command, approve it, and be
told the program was not on a list."
  (chat-test-with-temp-dir
   (let ((chat-approval-consent 'human)
         (chat-work-directory (expand-file-name "work/" temp-dir)))
     ;; `make' is not on `chat-work-task-allowed-commands', and that is
     ;; exactly the case a person's yes has to settle.
     (should-not (member "make" chat-work-task-allowed-commands))
     (should (chat-work-task-refusal "make test"))
     ;; With consent the tool starts it instead of refusing.  `env true'
     ;; stands in for the build: absent from the list, present on the
     ;; machine, and over immediately.
     (should-not (member "env" chat-work-task-allowed-commands))
     (should (chat-work-task-refusal "env true"))
     (let ((started (chat-work-task-start "env true")))
       (should started)
       (should (equal (cdr (assoc 'command started)) "env true")))
     ;; Without consent the same command is refused before anything starts.
     (let ((chat-approval-consent nil))
       (should-error (chat-work-task-start "env true"))))))

(ert-deftest chat-approval-a-grant-skips-the-question-not-the-rules ()
  "A grant means do not ask.  It does not mean the gate stops applying:
only a person looking at this particular command can decide that."
  (chat-test-with-grants
   (let ((chat-approval-consent 'grant)
         (chat-tool-shell-enabled t))
     (should-not (chat-approval-command-consent-p))
     (should (string-match-p
              "not available"
              (chat-tool-shell-execute "echo hi | tr a-z A-Z"))))))

(ert-deftest chat-approval-no-interactive-choice-reaches-dangerous-mode ()
  "None of the approval decisions may switch the mode."
  (chat-test-with-temp-dir
   (chat-test-with-grants
    (let* ((chat-session-directory temp-dir)
           (session (chat-session-create "Modes"))
           (chat-approval-mode 'manual)
           (chat-approval-required-tools '(shell_execute))
           (chat-approval-noninteractive-policy 'ask))
      (dolist (decision '(allow-once allow-session allow-tool allow-command))
        (let ((chat-approval-decision-function
               (lambda (&rest _args) decision)))
          (chat-approval-authorize
           (test-chat-approval-tool 'shell_execute)
           '(:name "shell_execute" :arguments (("command" . "rg -n x .")))
           session))
        (should-not (eq (chat-approval-effective-mode session) 'dangerous)))))))

(ert-deftest chat-approval-a-subagent-inherits-the-mode-it-was-started-in ()
  "A child session must not be able to promote itself."
  (let ((parent (make-chat-session :id "p" :name "P")))
    (setf (chat-session-approval-mode parent) 'manual)
    (setf (chat-session-approval-grants parent)
          (list (make-chat-approval-grant :tool 'shell_execute :scope 'tool
                                          :source 'session)))
    (let ((child (chat-subagent--child-session "kid" nil parent 1)))
      (should (eq (chat-session-approval-mode child) 'manual))
      (should (eq (chat-approval-effective-mode child) 'manual))
      ;; The parent's session grants stay with the parent.
      (should-not (chat-session-approval-grants child)))))

(ert-deftest chat-approval-set-mode-refuses-an-unknown-mode ()
  "A typo must not silently become a permissive setting."
  (let ((chat-approval-mode 'manual))
    (should-error (chat-approval-set-mode 'yolo))
    (should (eq chat-approval-mode 'manual))))

;;; Grants: four sources

(ert-deftest chat-approval-grants-report-where-they-came-from ()
  "Each of the four sources matches, and says which it is."
  (chat-test-with-grants
   (let* ((session (make-chat-session :id "s" :name "S"))
          (chat-tool-shell-whitelist '("rg "))
          (chat-approval-user-grants
           '((:tool files_read :scope tool))))
     (setf (chat-session-approval-grants session)
           (list (make-chat-approval-grant :tool 'work_task_start
                                           :scope 'command
                                           :pattern "make test"
                                           :source 'session)))
     (chat-approval-add-grant
      (make-chat-approval-grant :tool 'files_write :scope 'tool
                                :source 'runtime))
     ;; builtin
     (should (eq (chat-approval-grant-source
                 (chat-approval-grant-match
                  'shell_execute '(("command" . "pwd")) session))
                'builtin))
     ;; user, both the new list and the older shell one
     (should (eq (chat-approval-grant-source
                 (chat-approval-grant-match
                  'shell_execute '(("command" . "rg -n x .")) session))
                'user))
     (should (eq (chat-approval-grant-source
                 (chat-approval-grant-match 'files_read nil session))
                'user))
     ;; runtime
     (should (eq (chat-approval-grant-source
                 (chat-approval-grant-match 'files_write nil session))
                'runtime))
     ;; session
     (should (eq (chat-approval-grant-source
                 (chat-approval-grant-match
                  'work_task_start '(("command" . "make test")) session))
                'session))
     ;; and nothing matches what nobody granted
     (should-not (chat-approval-grant-match
                  'shell_execute '(("command" . "curl example.com")) session)))))

(ert-deftest chat-approval-command-patterns-keep-their-old-meaning ()
  "The matching rule is the one users already configured against."
  (should (chat-approval-grant-pattern-match-p "git log" "git log "))
  (should (chat-approval-grant-pattern-match-p "git log --oneline" "git log "))
  (should-not (chat-approval-grant-pattern-match-p "git logx" "git log "))
  (should (chat-approval-grant-pattern-match-p "pwd" "pwd"))
  (should-not (chat-approval-grant-pattern-match-p "pwd -P" "pwd"))
  (should-not (chat-approval-grant-pattern-match-p "lsof" "ls ")))

(ert-deftest chat-approval-directory-grants-compare-whole-path-segments ()
  "A directory grant covers what is under it and nothing beside it."
  (chat-test-with-grants
   (let ((chat-approval-grant-target-paths-function
          (lambda (_tool-id arguments)
            (list (cdr (assoc "path" arguments))))))
     (chat-approval-add-grant
      (make-chat-approval-grant :tool 'files_write :scope 'directory
                                :pattern "/a/b/" :source 'runtime))
     (should (chat-approval-grant-match
              'files_write '(("path" . "/a/b/c/f.txt"))))
     (should-not (chat-approval-grant-match
                  'files_write '(("path" . "/a/bb/f.txt")))))))

(ert-deftest chat-approval-runtime-grants-survive-a-restart ()
  "\"Always allow\" used to expire when Emacs did."
  (chat-test-with-temp-dir
   (let ((chat-approval-grants-file (expand-file-name "approvals.eld" temp-dir))
         (chat-approval-grants-persist t)
         (chat-approval--runtime-grants nil)
         (chat-approval--runtime-grants-loaded t))
     (chat-approval-add-grant
      (make-chat-approval-grant :tool 'shell_execute :scope 'command
                                :pattern "cargo build" :source 'runtime))
     (should (file-exists-p chat-approval-grants-file))
     ;; Forget everything in memory, as a fresh Emacs would.
     (setq chat-approval--runtime-grants nil
           chat-approval--runtime-grants-loaded nil)
     (let ((grant (chat-approval-grant-match
                   'shell_execute '(("command" . "cargo build")))))
       (should grant)
       (should (eq (chat-approval-grant-source grant) 'runtime))
       (should (chat-approval-grant-created-at grant))))))

(ert-deftest chat-approval-session-grants-are-not-written-to-disk ()
  "A judgement about this session does not outlive it."
  (chat-test-with-temp-dir
   (let ((chat-approval-grants-file (expand-file-name "approvals.eld" temp-dir))
         (chat-approval-grants-persist t)
         (chat-approval--runtime-grants nil)
         (chat-approval--runtime-grants-loaded t)
         (session (make-chat-session :id "s" :name "S")))
     (chat-approval-add-grant
      (make-chat-approval-grant :tool 'shell_execute :scope 'command
                                :pattern "make test" :source 'session)
      session)
     (should (chat-session-approval-grants session))
     (should-not chat-approval--runtime-grants)
     (should-not (file-exists-p chat-approval-grants-file)))))

(ert-deftest chat-approval-a-runtime-grant-records-who-added-it-and-when ()
  "A list grown over months is unreadable without this."
  (chat-test-with-grants
   (let ((session (make-chat-session :id "session-42" :name "S")))
     (let ((grant (chat-approval-add-grant
                   (make-chat-approval-grant :tool 'shell_execute
                                             :scope 'command
                                             :pattern "cargo test"
                                             :source 'runtime)
                   session)))
       (should (chat-approval-grant-created-at grant))
       (should (equal (chat-approval-grant-session-id grant) "session-42"))))))

(ert-deftest chat-approval-clearing-runtime-grants-leaves-the-others ()
  "Clearing what we granted must not clear what the user configured."
  (chat-test-with-grants
   (let ((chat-tool-shell-whitelist '("rg ")))
     (chat-approval-add-grant
      (make-chat-approval-grant :tool 'files_write :scope 'tool
                                :source 'runtime))
     (should (chat-approval-grant-match 'files_write nil))
     (chat-approval-clear-runtime-grants)
     (should-not (chat-approval-grant-match 'files_write nil))
     (should (chat-approval-grant-match
              'shell_execute '(("command" . "rg -n x ."))))
     (should (equal chat-tool-shell-whitelist '("rg "))))))

(ert-deftest chat-approval-builtin-and-user-grants-cannot-be-revoked ()
  "Those two are not ours: one is code, the other is their configuration."
  (chat-test-with-grants
   (should-error
    (chat-approval-revoke-grant
     (make-chat-approval-grant :scope 'tool :source 'builtin)))
   (should-error
    (chat-approval-revoke-grant
     (make-chat-approval-grant :scope 'tool :source 'user)))))

(ert-deftest chat-approval-revoking-a-runtime-grant-removes-it ()
  "What we added, we can drop."
  (chat-test-with-grants
   (let ((grant (chat-approval-add-grant
                 (make-chat-approval-grant :tool 'files_write :scope 'tool
                                           :source 'runtime))))
     (should (chat-approval-grant-match 'files_write nil))
     (should (chat-approval-revoke-grant grant))
     (should-not (chat-approval-grant-match 'files_write nil)))))

(ert-deftest chat-approval-whitelist-add-does-not-touch-the-user-list ()
  "The shell helper writes to the runtime store now."
  (chat-test-with-grants
   (let ((chat-tool-shell-whitelist nil))
     (chat-tool-shell-whitelist-add "cargo build ")
     (should-not chat-tool-shell-whitelist)
     (should (chat-tool-shell-whitelist-match-p "cargo build --release")))))

(ert-deftest chat-approval-a-cd-prefix-still-matches-the-grant-behind-it ()
  "`cd DIR && git log' has to match the grant for `git log '."
  (chat-test-with-grants
   (let ((chat-files-allowed-directories '("/tmp/")))
     (should (chat-tool-shell-whitelist-match-p "cd /tmp && git log -3"))
     (should (chat-tool-shell-whitelist-match-p "cd /tmp"))
     (should-not (chat-tool-shell-whitelist-match-p
                  "cd /tmp && curl example.com")))))

;;; What the user can see

(ert-deftest chat-approval-the-mode-is-visible-and-dangerous-stands-out ()
  "A user who has forgotten the mode is on is how this fails worst."
  (let ((chat-approval-mode 'manual))
    ;; The default is not announced, on the same grounds as the baseline
    ;; command: naming the ordinary case trains the reader to skip it.
    (should-not (chat-ui--status-approval nil)))
  (let ((chat-approval-mode 'guarded))
    (should (string-match-p "guarded" (chat-ui--status-approval nil))))
  ;; A configuration still set to the old name shows the current one, so
  ;; the status line and the mode in force cannot disagree.
  (let ((chat-approval-mode 'auto))
    (should (string-match-p "guarded" (chat-ui--status-approval nil))))
  (let* ((chat-approval-mode 'dangerous)
         (segment (chat-ui--status-approval nil)))
    (should (string-match-p "DANGEROUS" segment))
    (should (eq (get-text-property 0 'face segment) 'warning))))

(ert-deftest chat-approval-the-report-says-where-the-mode-came-from ()
  "Undoing a mode happens in different places depending on where it was set."
  (let ((chat-approval-mode 'guarded)
        (session (make-chat-session :id "s" :name "S")))
    (should (string-match-p "global default" (chat-approval-mode-report nil)))
    (setf (chat-session-approval-mode session) 'manual)
    (should (string-match-p "set on this session"
                            (chat-approval-mode-report session)))
    (should (string-match-p "manual" (chat-approval-mode-report session)))))

(provide 'test-chat-approval-modes)
;;; test-chat-approval-modes.el ends here
