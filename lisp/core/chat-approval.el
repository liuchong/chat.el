;;; chat-approval.el --- Approval flow for chat.el -*- lexical-binding: t -*-
;; Copyright (C) 2026 chat.el contributors
;; Author: chat.el contributors
;; Keywords: chat, tools, safety
;;; Commentary:
;; This module answers one question for every tool call: may it run.
;;
;; The answer has a name now.  `chat-approval-mode' is one of three:
;;
;;   manual     ask, unless a grant already covers the call
;;   guarded    a guard model rules on the call and the user is not asked
;;   dangerous  run everything, skip the gate as well as the prompt
;;
;; Six independent switches used to produce that answer between them, and
;; naming the combinations was not possible: a user who wanted to allow
;; everything reached for `chat-approval-enabled' and found it insufficient,
;; because the command gate sits below approval and refuses regardless.
;;
;; The mode also settles what the gate is worth.  Under `manual' a person
;; reads the command and decides, so the gate is advice: its reason goes into
;; the prompt and a yes overrides it.  Under `guarded' the guard model plays
;; that part, so the gate's refusal is evidence handed to it rather than the
;; end of the matter.  Under `dangerous' it is not consulted.  The old
;; ordering had approval first and the gate second with no way for one to
;; inform the other, so a person could approve a command and watch it be
;; refused anyway.
;;
;; The middle mode was called `auto' and did not deserve the name: it was
;; four table lookups that could only say no, so it never automatically
;; approved anything.  `auto' is still accepted on the way in, because
;; sessions on disk carry it.
;;
;; See specs/012-approval-modes-and-grants.md and
;; specs/013-guard-model-approval.md.
;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'chat-approval-grants)
(require 'chat-event)

;; Forward declarations
(declare-function chat-forged-tool-id "chat-tool-forge" (tool))
(declare-function chat-forged-tool-p "chat-tool-forge" (tool))
(declare-function chat-forged-tool-sensitivity "chat-tool-forge" (tool))
(declare-function chat-forged-tool-effects "chat-tool-forge" (tool))
(declare-function chat-forged-tool-approval-predicate "chat-tool-forge" (tool))
(declare-function chat-session-auto-approve-p "chat-session" (session))
(declare-function chat-session-auto-approve "chat-session" (session))
(declare-function chat-session-set-auto-approve "chat-session" (session value))
(declare-function chat-session-approval-mode "chat-session" (session))
(declare-function chat-session-set-approval-mode "chat-session" (session mode))
(declare-function chat-session-name "chat-session" (session))
(declare-function chat-session-id "chat-session" (session))
(declare-function chat-files--resolved-path "chat-files" (path))
(declare-function chat-files--tool-target-paths "chat-files" (tool-id arguments))
(declare-function chat-tool-caller--execution-directory
                  "chat-tool-caller" (&optional session))
(declare-function chat-command-gate-explain "chat-command-gate" (refusal))
;; The guard is an optional collaborator, reached through `fboundp'.  It
;; requires this module, so it cannot be required back; and a guard that is
;; not loaded is the same state as a guard with no provider configured,
;; which the design already has a name for.
(declare-function chat-approval-guard-enabled-p "chat-approval-guard"
                  (&optional session))
(declare-function chat-approval-guard-request "chat-approval-guard"
                  (tool call session callback))
(declare-function chat-approval-guard-never-allow-p "chat-approval-guard"
                  (tool-id arguments env))
(declare-function chat-approval-guard--environment "chat-approval-guard"
                  (session))
(declare-function chat-approval-guard-verdict-p "chat-approval-guard"
                  (object))
(declare-function chat-approval-guard-verdict-allows-p "chat-approval-guard"
                  (verdict))
(declare-function chat-approval-guard-verdict-decision "chat-approval-guard"
                  (verdict))
(declare-function chat-approval-guard-verdict-matched-rule "chat-approval-guard"
                  (verdict))
(declare-function chat-approval-guard-verdict-reason "chat-approval-guard"
                  (verdict))
(declare-function chat-approval-guard-verdict-confidence "chat-approval-guard"
                  (verdict))
(declare-function chat-approval-guard-verdict-model "chat-approval-guard"
                  (verdict))
(declare-function chat-approval-guard-verdict-elapsed "chat-approval-guard"
                  (verdict))
(declare-function chat-approval-guard-verdict-note-reference
                  "chat-approval-guard" (verdict reference kind))
(declare-function chat-approval-guard-log-verdict
                  "chat-approval-guard"
                  (verdict tool-id arguments mode &optional session task-id))
(declare-function chat-approval-guard-verdict-mark-shadow
                  "chat-approval-guard" (verdict))
(declare-function chat-approval-guard-remembered-refusal
                  "chat-approval-guard" (session tool-id arguments))
(declare-function chat-approval-guard-remember-refusal
                  "chat-approval-guard" (session tool-id arguments reason))
(defvar chat-approval-guard-shadow)
(defgroup chat-approval nil
  "Approval handling for chat.el."
  :group 'chat)

(defconst chat-approval-modes '(manual guarded dangerous)
  "The three answers to who decides whether a tool call may run.")

(defconst chat-approval-mode-aliases '((auto . guarded))
  "Older mode names and what they mean now.

Read-side only.  `chat-approval-normalize-mode' applies these; nothing
writes an alias back out.  `auto' is here because sessions on disk carry
`approvalMode: \"auto\"' and dropping it would read those sessions as the
default and quietly change what they may do.")

(defun chat-approval-normalize-mode (mode)
  "Return the current name for MODE, or nil when it is not a mode.

Accepts a symbol or a string, so callers reading from disk or from a
command argument do not each have to intern first."
  (let ((symbol (cond ((stringp mode) (intern mode))
                      ((symbolp mode) mode))))
    (cond
     ((memq symbol chat-approval-modes) symbol)
     ((alist-get symbol chat-approval-mode-aliases)))))

(defcustom chat-approval-mode 'manual
  "Who decides whether a tool call may run.

`manual'     a grant lets it through, otherwise the user is asked
`guarded'    a guard model rules on the call and the user is not asked
`dangerous'  everything runs; the command gate is skipped too

The default is `manual' rather than `guarded' because a guard denial is
not something the user is present to overrule.  It can be worked around --
the model is told and may take another route -- but a user who does not
know which mode they are in still cannot tell a policy denial apart from a
broken tool.

`dangerous' has to be set on purpose.  No interactive choice reaches it:
approving one command must never be a way to turn asking off altogether."
  :type '(choice (const :tag "Ask when not already granted" manual)
                 (const :tag "Let a guard model decide, never ask" guarded)
                 (const :tag "Allow everything (dangerous)" dangerous))
  :group 'chat-approval)

(defcustom chat-approval-enabled t
  "Whether risky tools require explicit approval.

Deprecated by `chat-approval-mode'.  Setting it to nil still skips
approval, but it never skipped the command gate, so it cannot express
\"allow everything\"; use `dangerous' for that."
  :type 'boolean
  :group 'chat-approval)
(defcustom chat-approval-required-tools
  '(files_write files_replace files_patch apply_patch shell_execute)
  "Tools that require approval before execution."
  :type '(repeat symbol)
  :group 'chat-approval)
(defcustom chat-approval-required-sensitivities
  '(personal correspondence credential network)
  "Data sensitivity classes that require explicit approval."
  :type '(repeat symbol)
  :group 'chat-approval)
(defcustom chat-approval-required-effects
  '(write outbound destructive)
  "Tool effects that require explicit approval."
  :type '(repeat symbol)
  :group 'chat-approval)
(defcustom chat-approval-risk-levels
  '((files_write . medium)
    (files_replace . medium)
    (files_patch . high)
    (apply_patch . high)
    (shell_execute . high))
  "Risk level mapping for tool approvals."
  :type '(alist :key-type symbol :value-type symbol)
  :group 'chat-approval)
(defcustom chat-approval-max-summary-length 160
  "Maximum length for argument summaries in approval prompts."
  :type 'integer
  :group 'chat-approval)
(defcustom chat-approval-noninteractive-policy 'deny
  "Policy for approvals in noninteractive sessions."
  :type '(choice (const :tag "Approve" approve)
                 (const :tag "Deny" deny)
                 (const :tag "Ask" ask))
  :group 'chat-approval)
(defcustom chat-approval-tool-creation-required t
  "Whether AI generated tools require explicit approval."
  :type 'boolean
  :group 'chat-approval)

(defcustom chat-approval-auto-approve-global nil
  "Whether to auto-approve tools without prompting.
When non-nil, tools in `chat-approval-auto-approve-tools' will be
executed without user confirmation."
  :type 'boolean
  :group 'chat-approval)

(defcustom chat-approval-auto-approve-tools
  '(files_read files_grep apply_patch)
  "Tools that can be auto-approved when `chat-approval-auto-approve-global' is t.
Note: shell_execute is excluded by default for security."
  :type '(repeat symbol)
  :group 'chat-approval)

(defcustom chat-approval-always-approve-tools nil
  "Tools that are always approved without prompting."
  :type '(repeat symbol)
  :group 'chat-approval)

(defcustom chat-approval-always-approve-directories nil
  "Directories whose file-write tool calls are always approved.
Only file writing tools with a clear directory scope can use this whitelist."
  :type '(repeat directory)
  :group 'chat-approval)

(defcustom chat-approval-decision-function nil
  "Optional function that returns an approval decision symbol."
  :type '(choice (const :tag "Default prompt" nil)
                 function)
  :group 'chat-approval)

(defcustom chat-approval-rules
  '(chat-approval-rule-command-gate
    chat-approval-rule-read-only
    chat-approval-rule-effects)
  "Rules consulted when `guarded' has no guard, in order, until one speaks.

This is the fallback, not the policy.  With a guard model configured the
guard decides and these are not consulted; they run when it is unavailable,
and the event log says the mode is operating degraded.

Each is called with (TOOL CALL SESSION) and returns `allow', nil for no
opinion, or a cons (deny . REASON).  Returning nil is what lets a rule
speak only about the calls it understands and leave the rest alone, which
is how a user adds one: write a function, put it at the front.

There is no declarative rule language, and one is not planned until a real
rule needs it.  A syntax designed now would only serve the cases we
imagine today."
  :type '(repeat function)
  :group 'chat-approval)

(defcustom chat-approval-command-refusal-functions
  '((shell_execute . chat-tool-shell-refusal)
    (work_task_start . chat-work-task-refusal)
    (programming_compile_task . chat-work-task-refusal))
  "How to ask a tool whether it would refuse a command.

Keyed by tool id because the policy differs: `shell_execute' takes one
command, while the two background compile/task entries allow `&&' between
several.  Each function takes the command string and returns a
`chat-command-gate-refusal' or nil.

The answer belongs to the tool, so it is asked rather than recomputed
here.  A copy of the policy in this module would drift from the one that
actually runs."
  :type '(alist :key-type symbol :value-type function)
  :group 'chat-approval)

(defvar chat-approval-consent nil
  "How the call now executing came to be permitted, or nil.

One of `dangerous', `grant', `rule', `human' or `guard'.  Bound around
execution by the tool caller so a tool can tell whether anything looked at
this command.  `chat-tool-shell' and `chat-work' consult it: their own gate
stays in place for callers that never went through approval, and it must
not refuse what a person -- or a guard holding the gate's own objection --
just approved.")

(defvar chat-approval--pending-request nil
  "Current pending approval request.")

(defvar chat-approval--pending-decision nil
  "Current approval decision selected through a command shortcut.")

;;; Which mode is in force

(defun chat-approval-effective-mode (&optional session)
  "Return the approval mode in force for SESSION.

A session may override the global default; `inherit' or nil means it does
not.  The older `auto-approve' flag is still honoured, because sessions on
disk carry it: a session saved with it set was running with approval off,
and reading it as the default would silently change what that session is
allowed to do."
  (let ((session-mode
         (chat-approval-normalize-mode
          (and session
               (fboundp 'chat-session-approval-mode)
               (chat-session-approval-mode session)))))
    (cond
     (session-mode session-mode)
     ((and session
           (fboundp 'chat-session-auto-approve)
           (eq (chat-session-auto-approve session) t))
      'guarded)
     ((chat-approval-normalize-mode chat-approval-mode))
     (t 'manual))))

(defun chat-approval-mode-description (mode)
  "Return a short label for MODE."
  (pcase (chat-approval-normalize-mode mode)
    ('manual "manual approval")
    ('guarded "guarded: a guard model decides")
    ('dangerous "DANGEROUS: allow everything")
    (_ (format "%s" mode))))

(defun chat-approval-mode-report (&optional session)
  "Return a sentence describing the approval mode in force for SESSION.

Says where the mode came from as well as what it is.  A user looking at
`guarded' needs to know whether this session chose it or the global
default did, because those are undone in different places."
  (let* ((session (or session
                      (and (boundp 'chat--current-session)
                           chat--current-session)))
         (mode (chat-approval-effective-mode session))
         (session-mode (chat-approval-normalize-mode
                        (and session
                             (fboundp 'chat-session-approval-mode)
                             (chat-session-approval-mode session)))))
    (format "Approval: %s (%s)"
            (chat-approval-mode-description mode)
            (if session-mode
                "set on this session"
              "global default"))))

(defun chat-approval-set-mode (mode &optional session)
  "Set MODE globally, or for SESSION when given.

Switching to `dangerous' asks for confirmation.  A user who forgets which
mode they left on is the worst way for this to fail, so the one mode that
runs anything cannot be entered without saying yes to it."
  (interactive
   (list (intern (completing-read "Approval mode: "
                                 (mapcar #'symbol-name chat-approval-modes)
                                 nil t))
         (and (boundp 'chat--current-session) chat--current-session)))
  (let ((mode (or (chat-approval-normalize-mode mode)
                  (user-error "Unknown approval mode: %s" mode))))
    (when (and (eq mode 'dangerous)
               (not noninteractive)
               (not (yes-or-no-p
                     "Dangerous mode runs every command without asking. Enable? ")))
      (user-error "Left approval mode unchanged"))
    (if session
        (when (fboundp 'chat-session-set-approval-mode)
          (chat-session-set-approval-mode session mode))
      (setq chat-approval-mode mode))
    mode))

;;; Fallback rules, for when `guarded' has no guard to consult

(defun chat-approval--command-refusal (tool-id arguments)
  "Return the tool's refusal for the command in ARGUMENTS, or nil."
  (when-let* ((command (chat-approval--command-from-arguments arguments))
              (refuser (alist-get tool-id
                                  chat-approval-command-refusal-functions)))
    (when (fboundp refuser)
      (condition-case nil
          (funcall refuser command)
        (error nil)))))

(defun chat-approval--refusal-text (refusal)
  "Return readable text for REFUSAL."
  (if (and refusal (fboundp 'chat-command-gate-explain))
      (chat-command-gate-explain refusal)
    (format "%s" refusal)))

(defun chat-approval-rule-granted (tool call session)
  "Allow when a grant already covers this CALL of TOOL in SESSION.

Not in `chat-approval-rules' by default, because on the authorize path it
can never fire: grants are matched before the mode is branched on, so a
call that reaches the rules has already failed this test.  Kept for a user
who assembles their own rule list and wants the check explicit."
  (and (chat-approval-grant-match (chat-forged-tool-id tool)
                                  (plist-get call :arguments)
                                  session)
       'allow))

(defun chat-approval-rule-command-gate (tool call _session)
  "Let the tool's own command gate decide about CALL of TOOL."
  (let ((tool-id (chat-forged-tool-id tool))
        (arguments (plist-get call :arguments)))
    (when (and (chat-approval--command-from-arguments arguments)
               (alist-get tool-id chat-approval-command-refusal-functions))
      (if-let ((refusal (chat-approval--command-refusal tool-id arguments)))
          (cons 'deny (chat-approval--refusal-text refusal))
        'allow))))

(defun chat-approval-rule-read-only (tool _call _session)
  "Allow TOOL when reading is all it does and what it reads is not sensitive.

Sensitivity has to be part of this, not just effects.  An MCP tool always
declares its sensitivity as `network' while its effects come from the
remote end, so a remote that describes itself as read-only used to be
waved through on its own word.  Reading is not harmless when the thing
read is a credential."
  (let ((effects (and (chat-forged-tool-p tool)
                      (chat-forged-tool-effects tool)))
        (sensitivity (and (chat-forged-tool-p tool)
                          (chat-forged-tool-sensitivity tool))))
    (and effects
         (seq-every-p (lambda (effect) (eq effect 'read)) effects)
         (not (memq sensitivity chat-approval-required-sensitivities))
         'allow)))

(defun chat-approval-rule-effects (tool _call _session)
  "Deny TOOL when it writes, sends or destroys and no rule allowed it."
  (let* ((effects (and (chat-forged-tool-p tool)
                       (chat-forged-tool-effects tool)))
         (matched (seq-filter (lambda (effect)
                                (memq effect chat-approval-required-effects))
                              effects)))
    (when matched
      (cons 'deny
            (format "the fallback rules will not run a tool with %s effects; %s"
                    (mapconcat #'symbol-name matched ", ")
                    "approve it once in manual mode or grant it")))))

(defun chat-approval-evaluate-rules (tool call &optional session)
  "Return the first opinion `chat-approval-rules' has on CALL of TOOL."
  (seq-some (lambda (rule)
              (and (functionp rule)
                   (condition-case nil
                       (funcall rule tool call session)
                     (error nil))))
            chat-approval-rules))

(defun chat-approval-command-consent-p ()
  "Return non-nil when a person, a guard, or dangerous mode permitted this.

Tools call this before applying their own gate.  A gate that refuses what
somebody just read and approved adds no safety; it only voids the
decision.

`guard' is here for the same reason `human' is, and it is the whole point
of the guard: the gate's objection was handed to it as evidence and it
ruled anyway, so a gate that then refuses regardless makes the verdict
decoration.  That is the \"approved, then refused anyway\" fault written up
in docs/troubleshooting-pitfalls.md, and it is not worth having twice.

What that costs is that a wrong verdict skips the gate, which is why
`chat-approval-guard-never-allow-p' runs first and is a predicate rather
than a rule the guard weighs."
  (memq chat-approval-consent '(human guard dangerous)))

(defun chat-approval--context-session (&optional session)
  "Return SESSION or the chat session currently executing a tool, if any."
  (or session
      (and (boundp 'chat-tool-caller-current-session)
           chat-tool-caller-current-session)
      (and (boundp 'chat--current-session)
           chat--current-session)))

(defun chat-approval-dangerous-mode-p (&optional session)
  "Return non-nil when SESSION (or the current session) is in dangerous mode.

`dangerous' means stop protecting the operator: skip the command gate, skip
approval prompts, and run model-directed commands on the unrestricted
`local' execution backend (real HOME, inherited environment, network, no
sandbox profile).  That covers `shell_execute', background work tasks,
verification steps and REPL processes alike.

Only the named mode lifts isolation.  A one-off human or guard consent
never does -- approving one command must not take the rest of the session
out of the sandbox."
  (or (and (boundp 'chat-approval-consent)
           (eq chat-approval-consent 'dangerous))
      (eq (chat-approval-effective-mode
           (chat-approval--context-session session))
          'dangerous)))

(defun chat-approval--write-file-tool-p (tool-id)
  "Return non-nil when TOOL-ID is a file-writing tool."
  (memq tool-id '(files_write files_replace files_patch apply_patch)))

(defun chat-approval--normalize-directory (dir)
  "Return canonical directory path for DIR."
  (file-name-as-directory
   (if (fboundp 'chat-files--resolved-path)
       (chat-files--resolved-path dir)
     (expand-file-name dir))))

(defun chat-approval--directory-prefix-p (root dir)
  "Return non-nil when ROOT contains DIR."
  (let ((normalized-root (chat-approval--normalize-directory root))
        (normalized-dir (chat-approval--normalize-directory dir)))
    (string-prefix-p normalized-root normalized-dir)))

(defun chat-approval--directory-parent (dir)
  "Return the parent directory for DIR, or nil at filesystem root."
  (let* ((trimmed (directory-file-name (chat-approval--normalize-directory dir)))
         (parent (file-name-directory trimmed)))
    (when (and parent
               (not (string= trimmed "/"))
               (not (string= (chat-approval--normalize-directory parent)
                             (chat-approval--normalize-directory dir))))
      parent)))

(defun chat-approval--common-directory (dirs)
  "Return the narrowest shared ancestor directory for DIRS."
  (when dirs
    (let ((common (chat-approval--normalize-directory (car dirs))))
      (dolist (dir (cdr dirs))
        (let ((candidate (chat-approval--normalize-directory dir)))
          (while (and common
                      (not (chat-approval--directory-prefix-p common candidate)))
            (setq common (chat-approval--directory-parent common)))))
      (unless (or (null common)
                  (string= common "/"))
        common))))

(defun chat-approval--tool-target-directories (tool-id arguments &optional session)
  "Return canonical target directories for TOOL-ID and ARGUMENTS in SESSION."
  (let ((default-directory
         (or (and session
                  (fboundp 'chat-tool-caller--execution-directory)
                  (chat-tool-caller--execution-directory session))
             default-directory)))
    (condition-case nil
        (when-let ((paths (chat-files--tool-target-paths tool-id arguments)))
          (delete-dups
           (mapcar #'file-name-directory paths)))
      (error nil))))

(defun chat-approval--directory-scope (tool-id arguments &optional session)
  "Return the directory scope for TOOL-ID and ARGUMENTS in SESSION, or nil."
  (when (chat-approval--write-file-tool-p tool-id)
    (chat-approval--common-directory
     (chat-approval--tool-target-directories tool-id arguments session))))

(defun chat-approval-tool-required-p (tool-or-id &optional call)
  "Return non-nil when TOOL-OR-ID requires approval for CALL.
Forged tools are governed by their sensitivity, effects, and optional
dynamic approval predicate in addition to the legacy tool id list."
  (let* ((tool (and (chat-forged-tool-p tool-or-id) tool-or-id))
         (tool-id (if tool (chat-forged-tool-id tool) tool-or-id))
         (sensitivity (and tool (chat-forged-tool-sensitivity tool)))
         (effects (and tool (chat-forged-tool-effects tool)))
         (predicate (and tool (chat-forged-tool-approval-predicate tool))))
    (or (memq tool-id chat-approval-required-tools)
        (memq sensitivity chat-approval-required-sensitivities)
        (seq-some (lambda (effect)
                    (memq effect chat-approval-required-effects))
                  effects)
        (and predicate (funcall predicate call)))))

(defun chat-approval-shortcut-summary (tool-id &optional directory)
  "Return a human-readable shortcut summary for TOOL-ID and DIRECTORY."
  (mapconcat #'identity
             (chat-approval--action-hints tool-id directory)
             ", "))

(defun chat-approval-pending-message (tool actions)
  "Return a native approval hint message for TOOL and ACTIONS."
  (format "Approval pending for %s. Use %s."
          tool
          (mapconcat #'identity actions ", ")))

(defun chat-approval--summarize-value (value)
  "Return a short string summary for VALUE."
  (let ((printed (if (stringp value)
                     value
                   (prin1-to-string value))))
    (truncate-string-to-width printed chat-approval-max-summary-length nil nil t)))
(defun chat-approval--summarize-arguments (arguments)
  "Return a readable summary string for ARGUMENTS."
  (if (null arguments)
      "no arguments"
    (mapconcat
     (lambda (entry)
       (format "%s=%s"
               (car entry)
               (chat-approval--summarize-value (cdr entry))))
     arguments
     ", ")))
(defun chat-approval--risk-level (tool-id)
  "Return the configured risk level for TOOL-ID."
  (or (alist-get tool-id chat-approval-risk-levels)
      'medium))
(defun chat-approval--prompt (tool-id arguments &optional directory)
  "Build an approval prompt for TOOL-ID with ARGUMENTS and DIRECTORY.

When the tool's own gate would refuse the command, its reason is part of
the question.  The gate knows something the reader may not -- that this is
a writing git subcommand, say -- and withholding it while asking them to
decide leaves them deciding without it."
  (let ((refusal (chat-approval--command-refusal tool-id arguments)))
    (format "Approve %s risk tool %s with %s?%s Shortcuts: %s. "
            (chat-approval--risk-level tool-id)
            tool-id
            (chat-approval--summarize-arguments arguments)
            (if refusal
                (format " Outside the rules: %s."
                        (chat-approval--refusal-text refusal))
              "")
            (chat-approval-shortcut-summary tool-id directory))))

(defun chat-approval--allow-noninteractive-p ()
  "Return non nil when the current noninteractive policy allows execution."
  (and noninteractive
       (eq chat-approval-noninteractive-policy 'approve)))

(defun chat-approval--deny-noninteractive-p ()
  "Return non nil when the current noninteractive policy denies execution."
  (and noninteractive
       (eq chat-approval-noninteractive-policy 'deny)))

(defun chat-approval--auto-approve-p (tool-id &optional session)
  "Return non-nil when TOOL-ID would run without asking in SESSION.

A query, not a step in the decision.  `chat-approval-authorize' does not
call it: every one of these settings is read as a grant now, and a session
flag is read as a mode, so answering the same question twice by two routes
would let them disagree and would make the mode decoration."
  (and (or (chat-approval-grant-match tool-id nil session)
           (memq (chat-approval-effective-mode session) '(guarded dangerous)))
       t))

(defun chat-approval--notify (observer event)
  "Send EVENT to OBSERVER."
  (when observer
    (funcall observer event)))

(defun chat-approval--command-from-arguments (arguments)
  "Return shell command string from ARGUMENTS when present."
  (cdr (assoc "command" arguments)))

(defun chat-approval--decision-options (tool-id &optional directory)
  "Return available decisions for TOOL-ID and DIRECTORY."
  (append
   '(("allow once" . allow-once)
     ("allow for session" . allow-session)
     ("always allow this tool" . allow-tool))
   (when directory
     (list (cons (format "always allow this directory (%s)" directory)
                 'allow-directory)))
   (when (eq tool-id 'shell_execute)
     '(("always allow this command" . allow-command)))
   '(("deny" . deny))))

(defun chat-approval--action-hints (tool-id &optional directory)
  "Return display strings for TOOL-ID approval shortcuts and DIRECTORY."
  (append
   '("C-c C-a once"
     "C-c C-s session"
     "C-c C-t tool")
   (when directory
     '("C-c C-f directory"))
   (when (eq tool-id 'shell_execute)
     '("C-c C-c command"))
   '("C-c C-d deny")))

(defun chat-approval--event-context (tool-id arguments &optional session)
  "Return shared event context for TOOL-ID and ARGUMENTS in SESSION."
  (let ((command (chat-approval--command-from-arguments arguments))
        (directory (chat-approval--directory-scope tool-id arguments session)))
    (append
     (list :risk (chat-approval--risk-level tool-id))
     (list :actions (chat-approval--action-hints tool-id directory))
     (when directory
       (list :directory directory))
     (when command
       (list :command command)))))

(defun chat-approval--lifecycle-payload
    (tool-id arguments mode &optional consent reason decision-event session)
  "Return bounded approval facts for lifecycle persistence."
  (let ((command (chat-approval--command-from-arguments arguments)))
    (delq
     nil
     (list
      (cons 'tool (symbol-name tool-id))
      (cons 'mode (format "%s" mode))
      (cons 'argument_count (if (listp arguments) (length arguments) 0))
      (when command
        (cons 'command (chat-approval--summarize-value command)))
      (when-let* ((directory
                   (chat-approval--directory-scope tool-id arguments session)))
        (cons 'directory directory))
      (when consent (cons 'consent (format "%s" consent)))
      (when decision-event
        (cons 'decision
              (format "%s" (plist-get decision-event :decision))))
      (when decision-event
        (cons 'approved
              (if (plist-get decision-event :approved) t :json-false)))
      (when (plist-get decision-event :matched-rule)
        (cons 'matched_rule (plist-get decision-event :matched-rule)))
      (when (plist-get decision-event :model)
        (cons 'model (plist-get decision-event :model)))
      (when (plist-get decision-event :degraded)
        (cons 'degraded t))
      (when-let* ((final-reason
                   (or reason (plist-get decision-event :reason))))
        (cons 'reason
              (chat-approval--summarize-value final-reason)))))))

(defun chat-approval--lifecycle-observer (observer state)
  "Return an observer that captures the final approval event in STATE."
  (lambda (event)
    (when (eq (plist-get event :type) 'approval)
      (setcar state event))
    (chat-approval--notify observer event)))

(defun chat-approval--emit-lifecycle-request
    (tool-id arguments mode session call)
  "Record one permission request for TOOL-ID and CALL."
  (chat-event-emit
   'permission-requested
   :session-id (and session (chat-session-id session))
   :task-id (plist-get call :id)
   :source 'approval
   :subject call
   :payload (chat-approval--lifecycle-payload
             tool-id arguments mode nil nil nil session)))

(defun chat-approval--emit-lifecycle-resolution
    (tool-id arguments mode session call consent reason decision-event)
  "Record the effective permission result for TOOL-ID and CALL."
  (chat-event-emit
   'permission-resolved
   :session-id (and session (chat-session-id session))
   :task-id (plist-get call :id)
   :source 'approval
   :subject call
   :payload
   (chat-approval--lifecycle-payload
    tool-id arguments mode consent reason decision-event session)))

(defun chat-approval--set-pending-decision (decision)
  "Set pending approval DECISION and exit the minibuffer when active."
  (unless chat-approval--pending-request
    (user-error "No pending approval"))
  (setq chat-approval--pending-decision decision)
  (when (active-minibuffer-window)
    (exit-minibuffer)))

(defun chat-approval-allow-once ()
  "Approve the current pending request once."
  (interactive)
  (chat-approval--set-pending-decision 'allow-once))

(defun chat-approval-allow-session ()
  "Approve the current pending request for this session."
  (interactive)
  (chat-approval--set-pending-decision 'allow-session))

(defun chat-approval-allow-tool ()
  "Always approve the current pending tool."
  (interactive)
  (chat-approval--set-pending-decision 'allow-tool))

(defun chat-approval-allow-command ()
  "Always approve the current pending shell command."
  (interactive)
  (chat-approval--set-pending-decision 'allow-command))

(defun chat-approval-allow-directory ()
  "Always approve the current pending directory for file-write tools."
  (interactive)
  (chat-approval--set-pending-decision 'allow-directory))

(defun chat-approval-deny ()
  "Deny the current pending approval request."
  (interactive)
  (chat-approval--set-pending-decision 'deny))

(defun chat-approval--install-minibuffer-bindings ()
  "Install approval shortcut bindings in the active minibuffer."
  (use-local-map (copy-keymap (current-local-map)))
  (local-set-key (kbd "C-c C-a") #'chat-approval-allow-once)
  (local-set-key (kbd "C-c C-s") #'chat-approval-allow-session)
  (local-set-key (kbd "C-c C-t") #'chat-approval-allow-tool)
  (local-set-key (kbd "C-c C-f") #'chat-approval-allow-directory)
  (local-set-key (kbd "C-c C-c") #'chat-approval-allow-command)
  (local-set-key (kbd "C-c C-d") #'chat-approval-deny))

(defun chat-approval--prompt-for-decision (tool-id arguments &optional session)
  "Prompt for TOOL-ID with ARGUMENTS in SESSION and return a decision symbol."
  (let* ((directory (chat-approval--directory-scope tool-id arguments session))
         (chat-approval--pending-request
          (list :tool-id tool-id
                :arguments arguments
                :directory directory))
         (choices (chat-approval--decision-options tool-id directory))
         (chat-approval--pending-request
          (append chat-approval--pending-request
                  (list :options choices)))
         (chat-approval--pending-decision nil)
         choice)
    (unwind-protect
        (progn
          (setq choice
                (minibuffer-with-setup-hook
                    #'chat-approval--install-minibuffer-bindings
                  (completing-read
                   (chat-approval--prompt tool-id arguments directory)
                   (mapcar #'car choices)
                   nil
                   t
                   nil
                   nil
                   "allow once")))
          (or chat-approval--pending-decision
              (cdr (assoc choice choices))
              'deny))
      (setq chat-approval--pending-request nil)
      (setq chat-approval--pending-decision nil))))

(defun chat-approval--decide (tool-id arguments &optional session)
  "Return approval decision for TOOL-ID with ARGUMENTS and SESSION."
  (cond
   (chat-approval-decision-function
    (funcall chat-approval-decision-function tool-id arguments session))
   (t
    (chat-approval--prompt-for-decision tool-id arguments session))))

(defun chat-approval--decision-grant (tool-id arguments decision &optional session)
  "Return the grant DECISION asks for on TOOL-ID with ARGUMENTS in SESSION.

The five allowing decisions differ in two dimensions only: what they
cover, and how long they last.  `allow-session' covers exactly what
`allow-tool' or `allow-command' would; it is stored on the session instead
of on disk.  It used to switch the whole session to automatic approval, so
approving one command stopped every later tool from asking -- the option
said \"this\" and did \"everything\"."
  (let ((command (cdr (assoc "command" arguments)))
        (directory (chat-approval--directory-scope tool-id arguments session)))
    (pcase decision
      ('allow-tool
       (make-chat-approval-grant :tool tool-id :scope 'tool :source 'runtime))
      ('allow-command
       (when command
         (make-chat-approval-grant :tool tool-id :scope 'command
                                   :pattern command :source 'runtime)))
      ('allow-directory
       (when directory
         (make-chat-approval-grant :tool tool-id :scope 'directory
                                   :pattern directory :source 'runtime)))
      ('allow-session
       (if command
           (make-chat-approval-grant :tool tool-id :scope 'command
                                     :pattern command :source 'session)
         (make-chat-approval-grant :tool tool-id :scope 'tool
                                   :source 'session)))
      (_ nil))))

(defun chat-approval--apply-decision (tool-id arguments decision &optional session)
  "Apply DECISION for TOOL-ID with ARGUMENTS and SESSION."
  (pcase decision
    ('allow-once t)
    ('deny nil)
    ((or 'allow-session 'allow-tool 'allow-command 'allow-directory)
     (if-let ((grant (chat-approval--decision-grant
                      tool-id arguments decision session)))
         (progn (chat-approval-add-grant grant session) t)
       ;; Nothing to remember, because the call had no command or no
       ;; directory to name.  The person still said yes, so this call runs.
       t))
    (_ nil)))

(defun chat-approval--grant-scope (decision)
  "Return the whitelist event scope DECISION produces, or nil."
  (pcase decision
    ('allow-tool 'tool)
    ('allow-command 'command)
    ('allow-directory 'directory)
    ('allow-session 'session)
    (_ nil)))

(defun chat-approval--notify-whitelist-update
    (observer tool-id decision arguments &optional session)
  "Tell OBSERVER what DECISION recorded for TOOL-ID with ARGUMENTS."
  (when-let* ((scope (chat-approval--grant-scope decision))
              (pattern (pcase decision
                         ('allow-directory
                          (chat-approval--directory-scope
                           tool-id arguments session))
                         (_ (or (chat-approval--command-from-arguments arguments)
                                (symbol-name tool-id))))))
    (chat-approval--notify
     observer
     (list :type 'whitelist-update
           :tool (symbol-name tool-id)
           :scope scope
           :pattern pattern
           :approved t))))

(defun chat-approval--authorize-by-rules (tool tool-id arguments session observer)
  "Decide CALL of TOOL from `chat-approval-rules' with no guard to consult.
Returns the consent symbol, or nil after telling OBSERVER why not.

Every event this reports carries `:degraded t'.  Under `guarded' the guard
is meant to decide; falling back to a table that can only say no is a
worse mode than the one the user asked for, and the one thing that must
not happen is for it to look the same from outside."
  (let ((verdict (chat-approval-evaluate-rules
                  tool (list :arguments arguments) session)))
    (pcase verdict
      ('allow
       (chat-approval--notify
        observer
        (append (list :type 'approval
                      :tool (symbol-name tool-id)
                      :decision 'guarded-fallback
                      :degraded t
                      :approved t)
                (chat-approval--event-context tool-id arguments session)))
       'rule)
      (`(deny . ,reason)
       (chat-approval--notify
        observer
        (append (list :type 'approval
                      :tool (symbol-name tool-id)
                      :decision 'guarded-fallback
                      :degraded t
                      :approved nil
                      :reason reason)
                (chat-approval--event-context tool-id arguments session)))
       nil)
      (_
       ;; No rule had an opinion.  With no guard and nobody to ask, running
       ;; an unexamined write is the one outcome this mode must not produce,
       ;; so silence means no.
       (chat-approval--notify
        observer
        (append (list :type 'approval
                      :tool (symbol-name tool-id)
                      :decision 'guarded-fallback
                      :degraded t
                      :approved nil
                      :reason (concat "no guard model is configured and no "
                                      "fallback rule allowed this call"))
                (chat-approval--event-context tool-id arguments session)))
       nil))))

(defconst chat-approval--fell-through '--fell-through
  "What the fast path returns when it has no answer.

A sentinel rather than nil, because nil is a decision here: the fast path
returning \"no opinion\" and returning \"denied\" have to be different
values or the mode branch runs after a refusal.")

(defun chat-approval--fast-path (tool call session observer)
  "Decide CALL of TOOL without consulting the mode, or return no opinion.

The steps here are the ones that do not depend on which mode is in force,
and keeping them ahead of the mode branch is load-bearing in two ways.

It is what makes `guarded' affordable: a grant or a tool that needs no
approval is settled without a model request, so the guard only ever sees
the calls that are actually in question.

And it is why a shadow run under `manual' produces samples worth tuning
on.  Because nothing here asks which mode it is, the set of calls that
reach a person under `manual' is the same set that reaches the guard under
`guarded'.  Move one of these steps inside a mode branch and that stops
being true -- the samples would then come from a different distribution
than the one they are used to tune."
  (let ((tool-id (chat-forged-tool-id tool))
        (arguments (plist-get call :arguments))
        (mode (chat-approval-effective-mode session)))
    (cond
     ((eq mode 'dangerous)
      (chat-approval--notify
       observer
       (append (list :type 'approval
                     :tool (symbol-name tool-id)
                     :decision 'dangerous-mode
                     :approved t)
               (chat-approval--event-context tool-id arguments session)))
      'dangerous)
     ((not chat-approval-enabled) 'rule)
     ((not (chat-approval-tool-required-p tool call)) 'rule)
     ((when-let ((grant (chat-approval-grant-match tool-id arguments session)))
        (chat-approval--notify
         observer
         (append (list :type 'approval
                       :tool (symbol-name tool-id)
                       :decision 'granted
                       :approved t
                       :source (chat-approval-grant-source grant)
                       :scope (chat-approval-grant-scope grant))
                 (when (eq (chat-approval-grant-scope grant) 'directory)
                   (list :directory (chat-approval-grant-pattern grant)))
                 (chat-approval--event-context tool-id arguments session)))
        'grant))
     (t chat-approval--fell-through))))

(defun chat-approval--ask-a-person (tool-id arguments session observer)
  "Ask about TOOL-ID with ARGUMENTS in SESSION and return the consent, or nil."
  (let ((directory (chat-approval--directory-scope
                    tool-id arguments session)))
    (cond
     ((chat-approval--allow-noninteractive-p) 'rule)
     ((chat-approval--deny-noninteractive-p) nil)
     (t
      (let ((prompt (chat-approval--prompt tool-id arguments directory)))
        (chat-approval--notify
         observer
         (append
          (list :type 'approval-pending
                :tool (symbol-name tool-id)
                :prompt prompt
                :options (chat-approval--decision-options tool-id directory))
          (chat-approval--event-context tool-id arguments session)))
        (let* ((decision (chat-approval--decide tool-id arguments session))
               (approved (chat-approval--apply-decision
                          tool-id arguments decision session)))
          (chat-approval--notify-whitelist-update
           observer tool-id decision arguments session)
          (chat-approval--notify
           observer
           (append
            (list :type 'approval
                  :tool (symbol-name tool-id)
                  :decision decision
                  :approved approved)
            (chat-approval--event-context tool-id arguments session)))
          (and approved 'human)))))))

;;; The guard branch

(defun chat-approval--floor-refusal (tool-id arguments session)
  "Return a reason no verdict can override for TOOL-ID with ARGUMENTS, or nil.

Evaluated before a request is made, so a call the floor refuses costs no
model call and is refused by the layer that actually knows why."
  (when (and (fboundp 'chat-approval-guard-never-allow-p)
             (fboundp 'chat-approval-guard--environment))
    (condition-case err
        (chat-approval-guard-never-allow-p
         tool-id arguments (chat-approval-guard--environment session))
      ;; A floor that errors must refuse.  Reporting no reason would let the
      ;; call proceed to the guard, which is the one direction this must not
      ;; fail in.
      (error (format "the floor could not be evaluated: %s"
                     (error-message-string err))))))

(defun chat-approval--authorize-by-guard
    (tool tool-id arguments session observer callback)
  "Ask the guard about TOOL with ARGUMENTS and pass the outcome to CALLBACK.

CALLBACK receives (CONSENT REASON VERDICT).  The verdict is passed on
rather than logged here so that one caller decides what it is compared
against: under shadow running this same verdict is the sample, and logging
it twice would make the disagreement rate depend on the mode.

Three things settle a call before a request is made, and each of them is
cheaper and more certain than a verdict: the floor, which no verdict can
override; the command gate's own yes, which is a deterministic rule about
the exact command; and a refusal of this same call earlier in the session."
  (if-let ((floor (chat-approval--floor-refusal tool-id arguments session)))
      (progn
        (chat-approval--notify
         observer
         (append (list :type 'approval
                       :tool (symbol-name tool-id)
                       :decision 'floor
                       :approved nil
                       :reason floor)
                 (chat-approval--event-context tool-id arguments session)))
        ;; No verdict: the floor spends no model call, so there is no sample
        ;; here either.  Recording one would put calls in the log that the
        ;; guard never sees.
        (funcall callback nil floor nil))
    (cond
     ((chat-approval--gate-allows-p tool (list :arguments arguments) session)
      (chat-approval--notify
       observer
       (append (list :type 'approval
                     :tool (symbol-name tool-id)
                     :decision 'command-gate
                     :approved t)
               (chat-approval--event-context tool-id arguments session)))
      (funcall callback 'rule nil nil))
     ((chat-approval--remembered-refusal session tool-id arguments)
      (let ((remembered (chat-approval--remembered-refusal
                         session tool-id arguments)))
        (chat-approval--notify
         observer
         (append (list :type 'approval
                       :tool (symbol-name tool-id)
                       :decision 'guard-remembered
                       :approved nil
                       :reason remembered)
                 (chat-approval--event-context tool-id arguments session)))
        ;; No new verdict, so no new sample: this is the same call the log
        ;; already holds one for.
        (funcall callback nil remembered nil)))
     (t
      (chat-approval--request-verdict
       tool tool-id arguments session observer callback)))))

(defun chat-approval--gate-allows-p (tool call session)
  "Return non-nil when the command gate itself allows CALL of TOOL.

An enumerated, deterministic answer about this exact command, and where
one exists it is the end of the matter: paying a model request to
re-examine a command a rule already cleared spends money to make a
certain answer less certain."
  (eq (chat-approval-rule-command-gate tool call session) 'allow))

(defun chat-approval--remembered-refusal (session tool-id arguments)
  "Return why TOOL-ID with ARGUMENTS was already refused in SESSION, or nil."
  (when (fboundp 'chat-approval-guard-remembered-refusal)
    (chat-approval-guard-remembered-refusal session tool-id arguments)))

(defun chat-approval--request-verdict
    (tool tool-id arguments session observer callback)
  "Ask the guard about TOOL-ID with ARGUMENTS and report to CALLBACK."
  ;; Nothing is asked of the user under this mode, so the only sign a
  ;; request is out is this one.  Announced before it is sent and paired
  ;; with the verdict event that follows: a turn that looks idle while a
  ;; model is being consulted is how this mode gets read as a hang.
  (chat-approval--notify
   observer
   (append (list :type 'approval-guard-pending
                 :tool (symbol-name tool-id))
           (chat-approval--event-context tool-id arguments session)))
  (chat-approval-guard-request
   tool (list :arguments arguments) session
   (lambda (verdict)
     (let ((allowed (chat-approval-guard-verdict-allows-p verdict)))
       ;; Remembered so the same call does not buy the same answer twice,
       ;; and only the refusal is: an allow that outlived its request would
       ;; be a grant, and grants are something a person makes.
       (unless allowed
         (when (fboundp 'chat-approval-guard-remember-refusal)
           (chat-approval-guard-remember-refusal
            session tool-id arguments
            (chat-approval-guard-verdict-reason verdict))))
       (chat-approval--notify
        observer
        (append (list :type 'approval
                      :tool (symbol-name tool-id)
                      :decision 'guard
                      :approved (and allowed t)
                      :verdict (chat-approval-guard-verdict-decision verdict)
                      :matched-rule
                      (chat-approval-guard-verdict-matched-rule verdict)
                      :reason (chat-approval-guard-verdict-reason verdict)
                      :confidence
                      (chat-approval-guard-verdict-confidence verdict)
                      :model (chat-approval-guard-verdict-model verdict)
                      :elapsed (chat-approval-guard-verdict-elapsed verdict))
                (chat-approval--event-context tool-id arguments session)))
       ;; `guard' rather than `rule', and it sits beside `human' in
       ;; `chat-approval-command-consent-p'.  A verdict the tool then
       ;; refuses anyway would make the guard decoration, and the gate's
       ;; objection was already handed to it as evidence.
       (funcall callback
                (and allowed 'guard)
                (unless allowed
                  (chat-approval-guard-verdict-reason verdict))
                verdict)))))

;;; Shadow running

(defun chat-approval--shadow-p (session)
  "Return non-nil when the guard should run alongside SESSION's mode.

An orthogonal switch, not a fourth mode: whatever mode is in force keeps
deciding, and the verdict is recorded beside the answer that mode gave."
  (and (bound-and-true-p chat-approval-guard-shadow)
       (fboundp 'chat-approval-guard-request)
       (chat-approval--guard-available-p session)))

(defun chat-approval--guard-would-see-p (tool call session)
  "Return non-nil when CALL of TOOL is the sort a guard rules on.

The one question the shadow sampler has to get right: would this call
reach the guard under `guarded'?  Sampling anything else gives the tuning
set a distribution the guard never faces, and a prompt tuned on it does
not transfer.  So everything settled above or beside the verdict is
excluded here -- a tool that needs no approval, a grant, a command the
gate itself allows, and a call the floor refuses."
  (let ((tool-id (chat-forged-tool-id tool))
        (arguments (plist-get call :arguments)))
    (and chat-approval-enabled
         (chat-approval-tool-required-p tool call)
         (not (chat-approval-grant-match tool-id arguments session))
         (not (chat-approval--gate-allows-p tool call session))
         (not (chat-approval--floor-refusal tool-id arguments session)))))

(defun chat-approval--record-verdict
    (verdict tool-id arguments mode reference session &optional task-id)
  "Log VERDICT about TOOL-ID with ARGUMENTS under MODE, against REFERENCE.

REFERENCE is nil, or a cons of what actually decided and what sort of
answer that is -- `human', `rules' or `none'.  A reference is a comparison
and not ground truth, which is why its sort is kept: the fortieth allow a
tired person clicks is a noisy label, and offline analysis has to be able
to weigh it as one."
  (when (chat-approval-guard-verdict-p verdict)
    (when (and reference (fboundp 'chat-approval-guard-verdict-note-reference))
      (chat-approval-guard-verdict-note-reference
       verdict (car reference) (cdr reference)))
    (when (fboundp 'chat-approval-guard-log-verdict)
      (chat-approval-guard-log-verdict
       verdict tool-id arguments mode session task-id))))

(defun chat-approval--shadow-start (tool call session observer)
  "Begin a shadow verdict for CALL of TOOL and return a function to settle it.

The returned function takes (REFERENCE REFERENCE-KIND) -- what actually
decided, and whether that was a person, the fallback rules or the guard
itself -- and is called once the real decision is known.  Whichever of the
two arrives second writes the paired sample.

Returns a function that does nothing when shadow running is off or when
this call is not one a guard would rule on, so the caller has no branch to
forget and no mode has its own idea of what gets sampled."
  (if (not (and (chat-approval--shadow-p session)
                (chat-approval--guard-would-see-p tool call session)))
      #'ignore
    (let ((verdict nil)
          (reference nil)
          (reference-kind nil)
          (settled nil)
          (mode (chat-approval-effective-mode session))
          (tool-id (chat-forged-tool-id tool)))
      (cl-labels
          ((maybe-record
            ()
            (when (and verdict reference-kind (not settled))
              (setq settled t)
              (when (fboundp 'chat-approval-guard-verdict-mark-shadow)
                (chat-approval-guard-verdict-mark-shadow verdict))
              (chat-approval--record-verdict
               verdict tool-id (plist-get call :arguments) mode
               (cons reference reference-kind) session (plist-get call :id))
              (chat-approval--notify
               observer
               (append
                (list :type 'approval-shadow
                      :tool (symbol-name tool-id)
                      :mode mode
                      ;; Stated rather than left to the event's type,
                      ;; because a log line saying a guard ruled when it
                      ;; only watched is the one reading that must not be
                      ;; possible.
                      :shadow t
                      :verdict (chat-approval-guard-verdict-decision verdict)
                      :matched-rule
                      (chat-approval-guard-verdict-matched-rule verdict)
                      :reason (chat-approval-guard-verdict-reason verdict)
                      :confidence
                      (chat-approval-guard-verdict-confidence verdict)
                      :model (chat-approval-guard-verdict-model verdict)
                      :elapsed (chat-approval-guard-verdict-elapsed verdict)
                      :would-allow
                      (and (chat-approval-guard-verdict-allows-p verdict) t)
                      ;; The reference is a comparison, not ground truth.
                      ;; A person's fortieth "allow" is a noisy label, so
                      ;; offline analysis has to be able to see which kind
                      ;; of answer it is being measured against.
                      :reference (and reference t)
                      :reference-kind reference-kind)
                (chat-approval--event-context
                 tool-id (plist-get call :arguments) session))))))
        ;; Fire and forget.  The verdict changes nothing, so nothing waits
        ;; for it -- which is what lets this stay on under `manual' without
        ;; costing the user any latency.
        (condition-case nil
            (chat-approval-guard-request
             tool call session
             (lambda (result) (setq verdict result) (maybe-record)))
          (error nil))
        (lambda (real-consent kind)
          (setq reference real-consent)
          (setq reference-kind (or kind 'none))
          (maybe-record))))))

(defun chat-approval-authorize (tool call &optional session observer)
  "Decide whether CALL of TOOL may run, and say how it was permitted.

Returns nil when it may not, and otherwise one of `dangerous', `grant',
`rule' or `human' -- the caller binds that to `chat-approval-consent'
around execution so tools can tell whether a person saw this command.

Synchronous, so it cannot consult the guard: a verdict arrives in a
callback and there is nowhere here to wait for one.  Under `guarded' with
a guard available this therefore refuses, rather than quietly falling back
to the rules the guard exists to replace.  Callers on the live path use
`chat-approval-authorize-async'."
  (let* ((tool-id (chat-forged-tool-id tool))
         (arguments (plist-get call :arguments))
         (mode (chat-approval-effective-mode session))
         (decision-state (list nil))
         (observer (chat-approval--lifecycle-observer
                    observer decision-state)))
    (chat-approval--emit-lifecycle-request
     tool-id arguments mode session call)
    (let* ((fast (chat-approval--fast-path tool call session observer))
           (consent
            (cond
             ((not (eq fast chat-approval--fell-through)) fast)
             ((and (eq mode 'guarded)
                   (chat-approval--guard-available-p session))
              (chat-approval--notify
               observer
               (append (list :type 'approval
                             :tool (symbol-name tool-id)
                             :decision 'guard-unreachable
                             :approved nil
                             :reason
                             (concat "this entry point cannot consult the "
                                     "guard; call it asynchronously"))
                       (chat-approval--event-context
                        tool-id arguments session)))
              nil)
             ((eq mode 'guarded)
              (chat-approval--authorize-by-rules
               tool tool-id arguments session observer))
             (t (chat-approval--ask-a-person
                 tool-id arguments session observer)))))
      (chat-approval--emit-lifecycle-resolution
       tool-id arguments mode session call consent nil (car decision-state))
      consent)))

(defun chat-approval--guard-available-p (session)
  "Return non-nil when a guard verdict could be obtained for SESSION."
  (and (fboundp 'chat-approval-guard-enabled-p)
       (chat-approval-guard-enabled-p session)))

(defun chat-approval-authorize-async (tool call session observer callback)
  "Decide whether CALL of TOOL may run and pass the answer to CALLBACK.

CALLBACK receives (CONSENT REASON): CONSENT is nil or one of `dangerous',
`grant', `rule', `human' or `guard', and REASON is text explaining a
refusal.  The reason is part of the contract because a denial goes back to
the assistant as a tool result, and \"denied\" with nothing after it is
what sent it round the same loop for eight minutes.

Asynchronous because a guard verdict is, and every live tool execution
comes through here so that the guard covers all of it."
  (let* ((tool-id (chat-forged-tool-id tool))
         (arguments (plist-get call :arguments))
         (mode (chat-approval-effective-mode session))
         (decision-state (list nil))
         (observer (chat-approval--lifecycle-observer
                    observer decision-state))
         (finished nil)
         (finish
          (lambda (consent reason)
            (unless finished
              (setq finished t)
              (chat-approval--emit-lifecycle-resolution
               tool-id arguments mode session call consent reason
               (car decision-state))
              (funcall callback consent reason))))
         (fast nil))
    (chat-approval--emit-lifecycle-request
     tool-id arguments mode session call)
    (setq fast (chat-approval--fast-path tool call session observer))
    (cond
     ;; `dangerous' is a decision about the mode rather than a step the
     ;; fast path took, and it is the one mode where a shadow run measures
     ;; something the others cannot: real traffic that all ran, against
     ;; which a guard's denials are its false-denial rate.
     ((eq fast 'dangerous)
      (funcall (chat-approval--shadow-start tool call session observer)
               'dangerous 'none)
      (funcall finish 'dangerous nil))
     ((not (eq fast chat-approval--fell-through))
      (funcall finish fast nil))
     ;; Past this point the call is genuinely in question, which is exactly
     ;; the population a shadow run wants to sample: the same set in every
     ;; mode, because the steps above this are the same in every mode.
     ;; A guard that is shadowing decides nothing, in this mode as in any
     ;; other -- that is the whole of what shadow running means, and an
     ;; exception here would make the switch mean one thing under `manual'
     ;; and another under `guarded'.  So this mode falls back to the rules
     ;; while the shadow watches, and turning the switch off is what hands
     ;; the decision back to the guard.  Deliberate degradation, chosen by
     ;; setting the switch, and the reason the switch ships off.
     ((and (eq mode 'guarded)
           (chat-approval--guard-available-p session)
           (not (chat-approval--shadow-p session)))
      (chat-approval--authorize-by-guard
       tool tool-id arguments session observer
       (lambda (consent reason verdict)
         (chat-approval--record-verdict
          verdict tool-id arguments mode nil session (plist-get call :id))
         (funcall finish consent reason))))
     ((eq mode 'guarded)
      (let ((settle (chat-approval--shadow-start tool call session observer))
            (consent (chat-approval--authorize-by-rules
                      tool tool-id arguments session observer)))
        (funcall settle consent 'rules)
        (funcall finish consent
                 (unless consent
                   (if (chat-approval--shadow-p session)
                       (concat "the guard is running in shadow, so the "
                               "fallback rules decided, and they did not "
                               "allow this call")
                     (concat "no guard model is configured, and the "
                             "fallback rules did not allow this call"))))))
     (t
      ;; `manual', and the pairing worth having: the reference is a
      ;; person's actual decision, and the calls a person sees here are the
      ;; same set a guard would see under `guarded'.
      (let ((settle (chat-approval--shadow-start tool call session observer))
            (consent (chat-approval--ask-a-person
                      tool-id arguments session observer)))
        (funcall settle consent 'human)
        (funcall finish consent
                 (unless consent
                   "the user declined this call")))))))

(defalias 'chat-approval-request-tool-call #'chat-approval-authorize
  "Decide whether a tool call may run.

The older name, kept for callers outside this repository.  Its answer is
no longer a flag: every non-nil value says how the call was permitted, and
code that only tests for truth keeps working unchanged.")

(defun chat-approval-request-tool-creation (description spec)
  "Request approval for creating a generated tool from DESCRIPTION and SPEC."
  (let* ((tool-id (plist-get spec :id))
         (language (plist-get spec :language))
         (prompt (format
                  "Approve high risk tool creation %s in %s for %s? "
                  tool-id
                  language
                  (chat-approval--summarize-value description))))
    (cond
     ((not chat-approval-enabled) t)
     ((not chat-approval-tool-creation-required) t)
     ((chat-approval--allow-noninteractive-p) t)
     ((chat-approval--deny-noninteractive-p) nil)
     (t
      (y-or-n-p prompt)))))
(provide 'chat-approval)
;;; chat-approval.el ends here
