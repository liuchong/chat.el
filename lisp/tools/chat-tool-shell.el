;;; chat-tool-shell.el --- Shell command execution tool for chat.el -*- lexical-binding: t -*-

;;; Commentary:
;; This tool allows the AI to execute shell commands and get results.
;; Use with caution - only enable in trusted environments.

;;; Code:

(require 'chat-approval-grants)
(require 'chat-command-gate)
(require 'chat-execution)
(require 'chat-files)
(require 'chat-tool-forge)
(require 'seq)
(require 'subr-x)

(declare-function chat-approval-command-consent-p "chat-approval" ())
(declare-function chat-approval-dangerous-mode-p "chat-approval" (&optional session))

(defcustom chat-tool-shell-enabled nil
  "Enable shell command execution tool.
WARNING: Only enable in trusted environments."
  :type 'boolean
  :group 'chat)

(defcustom chat-tool-shell-allowed-commands
  '("ls" "cat" "pwd" "echo" "printf" "head" "tail" "grep" "find" "wc" "which"
    "type" "du" "stat" "sort" "uniq" "cut" "sed" "awk" "tr" "git" "sleep")
  "List of allowed shell commands for safety.

`git' is admitted per subcommand, not as a word: only the read-only ones
in `chat-command-gate-git-read-only-subcommands' pass, so `git log' runs
and `git push' does not.  It was absent for a long time with no reason
recorded, which cost more than it protected -- reading a repository's
history is what `cat' and `find' were already allowed to do the slow way,
and the work that needs it (release notes, changelogs, review) cannot be
done at all without it.

`sleep' is here so intentional delays block the tool call itself.  A
background `sleep' via work/compile tasks returns immediately and does
not wait, which is why models busy-polled forever after starting one."
  :type '(repeat string)
  :group 'chat)

(defcustom chat-tool-shell-whitelist '()
  "List of command patterns that can execute without approval.
Each pattern is matched against the command string:
- If pattern ends with space, matches any command starting with that pattern
- Otherwise, requires exact match
Examples:
  \"ls \" matches \"ls\", \"ls -l\", \"ls /path\"
  \"ls\" matches only \"ls\" exactly
  \"git status\" matches only \"git status\" exactly
  \"git \" matches \"git status\", \"git log\", etc."
  :type '(repeat string)
  :group 'chat)

(defcustom chat-tool-shell-default-whitelist
  '("pwd"
    "ls "
    "find "
    "du "
    "stat "
    "wc "
    "head "
    "tail "
    "grep "
    "which "
    "type "
    "sort "
    "uniq "
    "cut "
    "sed "
    "awk "
    "tr "
    ;; Read-only git, one subcommand at a time.  Not the pattern "git ",
    ;; which would also skip approval for `git push' -- the gate would
    ;; still refuse it, so nothing would happen, but a prompt that was
    ;; skipped for a command that then failed reads as a bug rather than
    ;; as a rule.
    "git log "
    "git show "
    "git diff "
    "git status "
    "git rev-parse "
    "git rev-list "
    "git describe "
    "git shortlog "
    "git blame "
    "git ls-files "
    "git for-each-ref "
    "git merge-base "
    "git tag "
    ;; Intentional delay that blocks the tool call. Exact match for the
    ;; program word plus a trailing space so `sleepx' does not match.
    "sleep ")
  "Built in readonly command patterns that bypass approval.
User configured patterns in `chat-tool-shell-whitelist' are checked in addition
to these defaults."
  :type '(repeat string)
  :group 'chat)

(defalias 'chat-tool-shell--split-command #'chat-command-gate-split
  "Parse a command into an argv list.

One splitter, in `chat-command-gate', because the gate has to agree with
the runner about where the words are: a second implementation that
tokenised `awk \\='a b\\=' differently would approve one command and run
another.")

(defalias 'chat-tool-shell--pattern-match-p
  #'chat-approval-grant-pattern-match-p
  "Return non-nil when a command matches a whitelist pattern.

The rule moved to `chat-approval-grants' when grants for other tools began
needing it.  One implementation, because the list a user reads and the
list a call is matched against have to be the same list.")

(defun chat-tool-shell--parse-cd-prefix (command)
  "Parse COMMAND as an optional safe `cd` prefix form.
Returns plist with :directory and optional :rest when matched."
  (when (string-match "\\`cd[ \t]+\\(.+?\\)\\(?:[ \t]*&&[ \t]*\\(.+\\)\\)?\\'" command)
    (let ((directory (string-trim (match-string 1 command)))
          (rest (match-string 2 command)))
      (when (and directory (not (string-empty-p directory)))
        (list :directory directory
              :rest (and rest (string-trim rest)))))))

(defun chat-tool-shell--safe-directory (directory)
  "Return a validated DIRECTORY for shell execution."
  (let* ((unquoted (car (chat-tool-shell--split-command directory)))
         (path (or unquoted directory)))
    (chat-files--safe-path-p path)))

(defcustom chat-tool-shell-timeout 60
  "Default timeout in seconds for foreground shell commands."
  :type 'integer
  :group 'chat)

(defcustom chat-tool-shell-max-timeout 300
  "Maximum timeout in seconds for foreground shell commands."
  :type 'integer
  :group 'chat)

(defcustom chat-tool-shell-output-max-lines 2000
  "Maximum lines of shell output kept in a tool result."
  :type 'integer
  :group 'chat)

(defcustom chat-tool-shell-output-max-chars 50000
  "Maximum characters of shell output kept in a tool result."
  :type 'integer
  :group 'chat)

(defun chat-tool-shell--truncate-output (output)
  "Return (TEXT . NOTE) after applying output limits to OUTPUT.
NOTE is nil when nothing was truncated.  Truncated output spills into
a temporary file and NOTE reports its path."
  (let* ((lines (split-string output "\n"))
         (kept-lines (if (> (length lines) chat-tool-shell-output-max-lines)
                         (seq-take lines chat-tool-shell-output-max-lines)
                       lines))
         (kept (string-join kept-lines "\n"))
         (kept (if (> (length kept) chat-tool-shell-output-max-chars)
                  (substring kept 0 chat-tool-shell-output-max-chars)
                kept))
         (omitted (- (length output) (length kept))))
    (if (<= omitted 0)
        (cons output nil)
      (let ((spill (make-temp-file "chat-shell-output-" nil ".log")))
        (with-temp-file spill
          (insert output))
        (cons kept
              (format "[output truncated: %d chars omitted; full output saved to %s]"
                      omitted spill))))))

(defun chat-tool-shell--format-result (stdout stderr exit-status timed-out timeout)
  "Format subprocess STDOUT and STDERR into a tool result string."
  (let* ((pair (chat-tool-shell--truncate-output stdout))
         (text (string-trim-right (car pair)))
         (stderr-note (unless (string-empty-p (string-trim (or stderr "")))
                        (format "[stderr]\n%s" (string-trim-right stderr))))
         (notes (delq nil
                      (list (cdr pair)
                            (and timed-out
                                 (format "[timed out after %d seconds]" timeout))
                            (and (not timed-out)
                                 (integerp exit-status)
                                 (not (zerop exit-status))
                                 (format "[exit status %d]" exit-status))))))
    (string-join (delq nil (list (unless (string-empty-p text) text)
                                 stderr-note
                                 (and notes (string-join notes "\n"))))
                 "\n")))

(defun chat-tool-shell-execute-unrestricted (command &optional timeout)
  "Execute COMMAND through the system shell and return the output.

Unlike `chat-tool-shell-execute' this applies neither the allowed command
list nor the shell metacharacter check, so pipes, redirection and
variables all work.  It is meant for a command a person typed, where the
person already decided what to run.  Never route model-supplied arguments
here; the AI tool path stays on `chat-tool-shell-execute'.

Runs in `default-directory' and reuses the timeout and output limits of
the argv path."
  (chat-tool-shell--run-argv
   (list shell-file-name shell-command-switch command)
   timeout))

(defun chat-tool-shell--execute-argv (command &optional timeout)
  "Execute COMMAND as a subprocess with TIMEOUT and output limits."
  (chat-tool-shell--run-argv (chat-tool-shell--split-command command) timeout))

(defun chat-tool-shell--dangerous-p ()
  "Return non-nil when this call runs under dangerous approval mode.

Delegates to `chat-approval-dangerous-mode-p': only the mode lifts
isolation, never a one-off human or guard consent."
  (and (fboundp 'chat-approval-dangerous-mode-p)
       (chat-approval-dangerous-mode-p)))

(defun chat-tool-shell--execution-request (argv timeout)
  "Build the execution request for ARGV with TIMEOUT.

Dangerous approval mode runs the command on the unrestricted local
backend: inherited environment, real HOME, network, no sandbox profile.
Every other mode stays on the inspect sandbox -- read-only project root,
no writes, no network, filtered environment."
  (if (chat-tool-shell--dangerous-p)
      (chat-execution-request-from-context
       argv
       :backend 'local
       :directory default-directory
       :environment process-environment
       :policy 'local
       :idempotency 'non-idempotent
       :timeout timeout
       :metadata '((kind . "shell-tool")))
    (chat-execution-request-from-context
     argv
     :backend (chat-execution-backend-for-policy 'inspect)
     :directory default-directory
     :environment process-environment
     :policy 'inspect
     :read-roots (list default-directory)
     :network nil
     :require-process-tree-cleanup t
     :idempotency 'read-only
     :timeout timeout
     :metadata '((kind . "shell-tool")))))

(defun chat-tool-shell--run-argv (argv &optional timeout)
  "Run ARGV as a subprocess with TIMEOUT and output limits.
The wait pumps `accept-process-output', so Emacs stays responsive
while the command runs.  Output beyond the configured limits is
truncated and spills into a temporary file."
  (let* ((default-directory (if (file-directory-p default-directory)
                                (file-name-as-directory default-directory)
                              (file-name-as-directory temporary-file-directory)))
         (timeout (min (or timeout chat-tool-shell-timeout)
                       chat-tool-shell-max-timeout))
         (buffer (generate-new-buffer " *chat-shell*"))
         (stderr-buffer (generate-new-buffer " *chat-shell-stderr*"))
         (process-environment (chat-command-gate-environment))
         (record nil)
         (proc nil)
         (deadline nil)
         (timed-out nil))
    (unwind-protect
        (progn
          (setq record
                (chat-execution-start
                 (chat-tool-shell--execution-request argv timeout)
                 :name "chat-shell"
                 :buffer buffer
                 :stderr stderr-buffer
                 :noquery t
                 ;; A pipe, not the pty Emacs hands out by default.  A pty
                 ;; can make a pager wait for input this tool cannot send.
                 :connection-type 'pipe
                 :sentinel #'ignore))
          (setq proc (chat-execution-native-handle record))
          (setq deadline (+ (float-time) timeout))
          (while (and (process-live-p proc)
                      (< (float-time) deadline))
            (accept-process-output proc 0.2))
          (when (eq (chat-execution-record-status record) 'timed-out)
            (setq timed-out t))
          (when (process-live-p proc)
            (setq timed-out t)
            (chat-execution-cancel record "shell command timed out"))
          ;; stderr is a second Emacs process.  The command process can exit
          ;; before its final pipe chunk reaches STDERR-BUFFER, so drain that
          ;; process under the same deadline before reading the result.
          (when-let* ((stderr-process (get-buffer-process stderr-buffer)))
            (while (and (process-live-p stderr-process)
                        (< (float-time) deadline))
              (accept-process-output stderr-process 0.05)))
          (chat-tool-shell--format-result
           (with-current-buffer buffer (buffer-string))
           ;; The default stderr sentinel appends a status line such as
           ;; "Process chat-shell stderr finished"; drop it.  The process
           ;; either process name may carry a <N> suffix when instances
           ;; overlap.
           (replace-regexp-in-string
            "\n?Process chat-shell\\(?:<[0-9]+>\\)? stderr\\(?:<[0-9]+>\\)? [^\n]*\n?\\'"
            ""
            (with-current-buffer stderr-buffer (buffer-string)))
           (and (not timed-out) (process-exit-status proc))
           timed-out
           timeout))
      (when (and record (chat-execution-live-p record))
        (chat-execution-cancel record "shell caller cleanup"))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (when (buffer-live-p stderr-buffer)
        (kill-buffer stderr-buffer)))))

(defun chat-tool-shell-runnable-tail (command)
  "Return the part of COMMAND that runs after a safe `cd DIR &&' prefix.

Returns nil when COMMAND has no such prefix or the directory is out of
bounds.  Registered with `chat-approval-grants' so a whitelisted `cd DIR
&& git log' still matches the grant for `git log ' without the grant store
having to know any shell syntax."
  (when-let ((cd-prefix (chat-tool-shell--parse-cd-prefix command)))
    (condition-case nil
        (progn
          (chat-tool-shell--safe-directory (plist-get cd-prefix :directory))
          (or (plist-get cd-prefix :rest) ""))
      (error nil))))

(setq chat-approval-grant-command-tail-function #'chat-tool-shell-runnable-tail)

(defun chat-tool-shell-whitelist-match-p (command)
  "Return non-nil if COMMAND may run without approval.

Asks `chat-approval-grants', so runtime and session grants count here too
and not only the two configured lists.  A bare `cd DIR' is allowed on its
own: it reports a directory and changes nothing."
  (let ((tail (chat-tool-shell-runnable-tail command)))
    (or (and tail (string-empty-p tail))
        (and (chat-approval-grant-match 'shell_execute
                                        (list (cons "command" command)))
             t))))

(defun chat-tool-shell-whitelist-add (pattern)
  "Record PATTERN as a runtime grant for `shell_execute'.

Goes to the runtime store rather than `chat-tool-shell-whitelist', which
belongs to the user.  Appending to their defcustom put entries they never
wrote into `M-x customize', risked a `custom-file' save writing them back,
and left no way to drop what the program had granted without dropping what
they had configured."
  (interactive "sCommand pattern to whitelist (e.g., 'ls ' or 'git status'): ")
  (chat-approval-add-grant
   (make-chat-approval-grant :tool 'shell_execute
                             :scope 'command
                             :pattern pattern
                             :source 'runtime))
  (when (called-interactively-p 'interactive)
    (message "Command pattern '%s' will run without approval" pattern)))

(defun chat-tool-shell-whitelist-remove (pattern)
  "Drop the runtime grant for PATTERN."
  (interactive
   (list (completing-read
          "Remove pattern: "
          (mapcar #'chat-approval-grant-pattern
                  (seq-filter (lambda (grant)
                                (eq (chat-approval-grant-scope grant) 'command))
                              (chat-approval-runtime-grants)))
          nil t)))
  (if-let ((grant (seq-find
                   (lambda (grant)
                     (equal (chat-approval-grant-pattern grant) pattern))
                   (chat-approval-runtime-grants))))
      (progn (chat-approval-revoke-grant grant)
             (when (called-interactively-p 'interactive)
               (message "Removed '%s'" pattern)))
    (setq chat-tool-shell-whitelist (delete pattern chat-tool-shell-whitelist))))

(defun chat-tool-shell-refusal (command)
  "Return why COMMAND may not run here, or nil when it may.

The reason is a `chat-command-gate-refusal', not a flag, because the
reader has to be told which rule closed on them.  A single \"not allowed\"
covers an unlisted program, a rejected metacharacter and a writing git
subcommand equally well, which means it distinguishes none of them, and a
reader who cannot tell them apart cannot fix the command -- they can only
abandon the approach, which is what happened."
  (let ((cd-prefix (chat-tool-shell--parse-cd-prefix command)))
    (if cd-prefix
        (condition-case nil
            (let ((rest (plist-get cd-prefix :rest)))
              (chat-tool-shell--safe-directory (plist-get cd-prefix :directory))
              (and rest (chat-tool-shell-refusal rest)))
          ;; The directory itself was refused, which the gate cannot say
          ;; because it is not the gate's question.
          (error (chat-command-gate-refusal-create
                  :code 'directory
                  :token (plist-get cd-prefix :directory)
                  :hint "Use a path inside the session's allowed directories")))
      (chat-command-gate-check command
                               :commands chat-tool-shell-allowed-commands
                               :separators nil))))

(defun chat-tool-shell-validate (command)
  "Return non-nil when COMMAND is allowed to run.

Kept as the boolean question because callers and tests ask it; the reason
lives in `chat-tool-shell-refusal'."
  (not (chat-tool-shell-refusal command)))

(defun chat-tool-shell--refusal-message (refusal command)
  "Return REFUSAL as the result text for COMMAND.

Adds the one thing this tool can do that the gate does not know about: a
`cd DIR && COMMAND' prefix is accepted, so a reader told that `&&' is
unavailable is not also told, wrongly, that there is no way to choose a
directory."
  (concat
   (chat-command-gate-explain refusal command)
   (when (and (eq (chat-command-gate-refusal-code refusal) 'metacharacter)
              (member (chat-command-gate-refusal-token refusal) '("&&" ";")))
     ". A single `cd DIR && COMMAND' prefix is the one exception and does work")))

(defun chat-tool-shell-execute (command &optional timeout)
  "Execute shell COMMAND and return output.
Optional TIMEOUT (seconds) overrides `chat-tool-shell-timeout' and is
capped by `chat-tool-shell-max-timeout'.

The command list applies unless somebody already took responsibility for
this command: a person who read it and approved it, or dangerous mode.
Checking the list afterwards would not make either case safer, it would
only overrule the decision -- which is what happened when a user approved
`make test' at the prompt and watched the gate refuse it anyway.

The list still applies to grants.  A grant skips the question, not the
rules; only a person looking at this particular command can do that."
  (if (not chat-tool-shell-enabled)
      "Error: Shell tool is disabled"
    (if (and (fboundp 'chat-approval-command-consent-p)
             (chat-approval-command-consent-p))
        (chat-tool-shell-execute-unrestricted command timeout)
      (if-let* ((refusal (chat-tool-shell-refusal command)))
          (chat-tool-shell--refusal-message refusal command)
        (condition-case err
            (let ((cd-prefix (chat-tool-shell--parse-cd-prefix command)))
              (if cd-prefix
                  (let ((safe-dir (chat-tool-shell--safe-directory
                                   (plist-get cd-prefix :directory)))
                        (rest (plist-get cd-prefix :rest)))
                    (if rest
                        (let ((default-directory (file-name-as-directory safe-dir)))
                          (chat-tool-shell-execute rest timeout))
                      (concat safe-dir "\n")))
                (chat-tool-shell--execute-argv command timeout)))
          (error (format "Error executing command: %s"
                         (error-message-string err))))))))

;; Register the tool
(chat-tool-forge-register
 (make-chat-forged-tool
  :id 'shell_execute
  :name "Shell Execute"
  ;; Generated from the variable, because the description is what the
  ;; model reads.  It used to be a literal string naming the same
  ;; programs, so adding one to the list left the description still
  ;; saying it was unavailable, and the model's picture of the tool drifts
  ;; away from the tool.
  :description
  (concat "Execute one shell command and return the output. "
          "Pipes, redirection and chaining are not available; send each "
          "command as its own call, except that a single "
          "`cd DIR && COMMAND' prefix is accepted. "
          "Use `sleep N' here when you need this tool call itself to wait; "
          "background work tasks that start sleep return immediately. "
          (chat-command-gate-describe chat-tool-shell-allowed-commands))
  :language 'elisp
  :parameters '((:name "command" :type "string" :required t)
                (:name "timeout" :type "number" :required nil))
  :compiled-function #'chat-tool-shell-execute
  :is-active t
  :usage-count 0
  :version "1.0.0"))

(provide 'chat-tool-shell)
;;; chat-tool-shell.el ends here
