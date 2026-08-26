;;; chat-tool-shell.el --- Shell command execution tool for chat.el -*- lexical-binding: t -*-

;;; Commentary:
;; This tool allows the AI to execute shell commands and get results.
;; Use with caution - only enable in trusted environments.

;;; Code:

(require 'chat-command-gate)
(require 'chat-files)
(require 'chat-tool-forge)
(require 'seq)
(require 'subr-x)

(defcustom chat-tool-shell-enabled nil
  "Enable shell command execution tool.
WARNING: Only enable in trusted environments."
  :type 'boolean
  :group 'chat)

(defcustom chat-tool-shell-allowed-commands
  '("ls" "cat" "pwd" "echo" "printf" "head" "tail" "grep" "find" "wc" "which"
    "type" "du" "stat" "sort" "uniq" "cut" "sed" "awk" "tr" "git")
  "List of allowed shell commands for safety.

`git' is admitted per subcommand, not as a word: only the read-only ones
in `chat-command-gate-git-read-only-subcommands' pass, so `git log' runs
and `git push' does not.  It was absent for a long time with no reason
recorded, which cost more than it protected -- reading a repository's
history is what `cat' and `find' were already allowed to do the slow way,
and the work that needs it (release notes, changelogs, review) cannot be
done at all without it."
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
    "git tag ")
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

(defun chat-tool-shell--whitelist-patterns ()
  "Return all whitelist patterns."
  (append chat-tool-shell-whitelist
          chat-tool-shell-default-whitelist))

(defun chat-tool-shell--pattern-match-p (command pattern)
  "Return non-nil when COMMAND matches whitelist PATTERN."
  (and (> (length pattern) 0)
       (if (= (aref pattern (1- (length pattern))) ? )
           (and (>= (length command) (1- (length pattern)))
                (string-equal (substring command 0 (1- (length pattern)))
                              (substring pattern 0 (1- (length pattern))))
                (or (= (length command) (1- (length pattern)))
                    (= (aref command (1- (length pattern))) ? )))
         (string-equal command pattern))))

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
         (proc nil)
         (timed-out nil))
    (unwind-protect
        (progn
          (setq proc (make-process
                      :name "chat-shell"
                      :buffer buffer
                      :command argv
                      :stderr stderr-buffer
                      :noquery t
                      ;; A pipe, not the pty Emacs hands out by default.
                      ;; A pty looks like a terminal, and a pager started
                      ;; because of it waits for a keystroke that cannot
                      ;; arrive -- so the command runs out its timeout and
                      ;; reports a timeout for a command that finished
                      ;; its work immediately.
                      :connection-type 'pipe
                      :sentinel #'ignore))
          (let ((deadline (+ (float-time) timeout)))
            (while (and (process-live-p proc)
                        (< (float-time) deadline))
              (accept-process-output proc 0.2)))
          (when (process-live-p proc)
            (setq timed-out t)
            (delete-process proc))
          (chat-tool-shell--format-result
           (with-current-buffer buffer (buffer-string))
           ;; The default stderr sentinel appends a status line such as
           ;; "Process chat-shell stderr finished"; drop it.  The process
           ;; name may carry a <N> suffix when instances overlap.
           (replace-regexp-in-string
            "\n?Process chat-shell\\(<[0-9]+>\\)? stderr [^\n]*\n?\\'"
            ""
            (with-current-buffer stderr-buffer (buffer-string)))
           (and (not timed-out) (process-exit-status proc))
           timed-out
           timeout))
      (when (and proc (process-live-p proc))
        (delete-process proc))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (when (buffer-live-p stderr-buffer)
        (kill-buffer stderr-buffer)))))

(defun chat-tool-shell-whitelist-match-p (command)
  "Return non-nil if COMMAND matches any pattern in whitelist.
Matching rules:
- If whitelist pattern ends with space, matches any command with that prefix
- Otherwise, requires exact match
- \"ls \" matches \"ls\", \"ls -l\", but not \"lsxxx\""
  (let ((patterns (chat-tool-shell--whitelist-patterns))
        (cd-prefix (chat-tool-shell--parse-cd-prefix command)))
    (or (seq-some (lambda (pattern)
                    (chat-tool-shell--pattern-match-p command pattern))
                  patterns)
        (when cd-prefix
          (condition-case nil
              (let ((rest (plist-get cd-prefix :rest)))
                (chat-tool-shell--safe-directory (plist-get cd-prefix :directory))
                (or (null rest)
                    (seq-some (lambda (pattern)
                                (chat-tool-shell--pattern-match-p rest pattern))
                              patterns)))
            (error nil))))))

(defun chat-tool-shell-whitelist-add (pattern)
  "Add PATTERN to the shell command whitelist."
  (interactive "sCommand pattern to whitelist (e.g., 'ls ' or 'git status'): ")
  (unless (member pattern chat-tool-shell-whitelist)
    (push pattern chat-tool-shell-whitelist)
    (message "Added '%s' to shell whitelist" pattern)))

(defun chat-tool-shell-whitelist-remove (pattern)
  "Remove PATTERN from the shell command whitelist."
  (interactive
   (list (completing-read "Remove pattern: " chat-tool-shell-whitelist nil t)))
  (setq chat-tool-shell-whitelist (delete pattern chat-tool-shell-whitelist))
  (message "Removed '%s' from shell whitelist" pattern))

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
capped by `chat-tool-shell-max-timeout'."
  (if (not chat-tool-shell-enabled)
      "Error: Shell tool is disabled"
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
        (error (format "Error executing command: %s" (error-message-string err)))))))

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
