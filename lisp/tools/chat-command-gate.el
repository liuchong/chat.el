;;; chat-command-gate.el --- One decision about what a command may run -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;;; Commentary:

;; Whether a model-supplied command may run, decided in one place.
;;
;; It used to be decided in two, which is how it came to be decided
;; differently.  `chat-tool-shell.el' had a hard allowlist of nineteen
;; read-only utilities; `chat-work.el' had nothing at all and handed its
;; argument straight to `sh -c'.  So the strict gate stopped the
;; convenient path while the same command went through the other one, and
;; the strictness bought nothing except time spent working around it.  A
;; strict gate next to an open window is not a boundary; it is a
;; boundary-shaped inconvenience.
;;
;; Two things follow from that, and they are the whole design:
;;
;; A refusal is data, not a sentence.  It carries which token failed and
;; why, so the caller can say what is wrong and what would work instead.
;; The old refusal was the word "not allowed" and a copy of the command,
;; which named none of the four different things that could have caused
;; it -- so the reader could not tell an unlisted program from a rejected
;; metacharacter, and had no way to find out but to guess.  A gate that
;; cannot say why it closed makes every caller reverse-engineer it.
;;
;; A policy is an argument, not a global.  Callers differ in what they
;; legitimately need: a foreground tool that runs one program through
;; `make-process' has no business accepting a pipeline, while a background
;; task runner exists to run shell lines and needs separators.  One
;; allowlist for both would either ban what the second one is for or
;; permit what the first one carefully avoids.  What is shared is the
;; decision, not the list.
;;
;; Read-only `git' is the case that prompted all of this.  It was missing
;; for no stated reason -- `git log' is as dangerous as `cat', which was
;; listed -- and its absence cost an agent six minutes of trying to read
;; commit subjects out of zlib-compressed objects with `grep', a route
;; that cannot work.  It is admitted here per subcommand rather than as
;; the word "git", because the allowlist matches first words and `git' as
;; a first word includes `git push --force'.
;;
;; The environment a command runs in is here too, next to the decision
;; about whether it may run, because both callers need both and because
;; admitting `git' without it would have admitted a command that hangs.
;; Emacs gives a subprocess a pty by default, a pty looks like a terminal,
;; and git seeing a terminal starts a pager that then waits for a
;; keystroke nobody can send.  See `chat-command-gate-environment'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

;; ------------------------------------------------------------------
;; Refusals
;; ------------------------------------------------------------------

(cl-defstruct (chat-command-gate-refusal
               (:constructor chat-command-gate-refusal-create))
  "Why a command was refused.

CODE is a symbol a test can assert on and a caller can branch on.  TOKEN
is the specific word that failed, so the reader is not left comparing the
whole command against a list.  HINT is what to do instead, and it is not
optional decoration: a refusal that does not say what would work is a
refusal the reader can only respond to by abandoning the approach, which
is what happened."
  code
  token
  hint)

(defun chat-command-gate-refused-p (value)
  "Return non-nil when VALUE is a refusal rather than an approval."
  (chat-command-gate-refusal-p value))

(defun chat-command-gate-explain (refusal &optional command)
  "Return REFUSAL as a sentence for the model that sent COMMAND.

Names the token, the reason and the way forward, in that order.  The
reason alone is what the old message gave, and it left the reader unable
to tell which of several rules it had hit."
  (if (not (chat-command-gate-refusal-p refusal))
      ""
    (let ((token (chat-command-gate-refusal-token refusal))
          (hint (chat-command-gate-refusal-hint refusal)))
      (string-join
       (delq nil
             (list
              (pcase (chat-command-gate-refusal-code refusal)
                ('empty "Error: no command given")
                ('metacharacter
                 (format "Error: the shell metacharacter %s is not available here"
                         token))
                ('unknown-command
                 (format "Error: the program %s is not on the allowed list"
                         token))
                ('git-subcommand
                 (format "Error: git %s is not one of the read-only git subcommands"
                         token))
                ('git-writes
                 (format "Error: git %s in this form can modify the repository"
                         token))
                ('git-option
                 (format "Error: the git option %s is not available here" token))
                ('denied-argument
                 (format "Error: the argument %s can write outside the command's output"
                         token))
                (_ (format "Error: command not allowed: %s" (or command ""))))
              hint))
       ". "))))

(defun chat-command-gate--refuse (code token hint)
  "Return a refusal with CODE, TOKEN and HINT."
  (chat-command-gate-refusal-create :code code :token token :hint hint))

;; ------------------------------------------------------------------
;; Splitting
;; ------------------------------------------------------------------

(defun chat-command-gate-split (command)
  "Parse COMMAND into an argv list.

Unlike `split-string-and-unquote', single quotes group anywhere in a
word, so commands like awk \\='BEGIN{...}\\=' file survive intact."
  (let ((len (length command))
        (idx 0)
        (args nil)
        (current nil)
        (in-token nil))
    (while (< idx len)
      (let ((ch (aref command idx)))
        (cond
         ((memq ch '(?\s ?\t ?\n))
          (when in-token
            (push (apply #'string (nreverse current)) args)
            (setq current nil
                  in-token nil)))
         ((eq ch ?\\)
          (setq in-token t)
          (when (< (1+ idx) len)
            (setq idx (1+ idx))
            (push (aref command idx) current)))
         ((eq ch ?')
          (setq in-token t)
          (setq idx (1+ idx))
          (while (and (< idx len) (not (eq (aref command idx) ?')))
            (push (aref command idx) current)
            (setq idx (1+ idx))))
         ((eq ch ?\")
          (setq in-token t)
          (setq idx (1+ idx))
          (while (and (< idx len) (not (eq (aref command idx) ?\")))
            (let ((inner (aref command idx)))
              (if (and (eq inner ?\\)
                       (< (1+ idx) len)
                       (memq (aref command (1+ idx)) '(?\" ?\\)))
                  (progn
                    (setq idx (1+ idx))
                    (push (aref command idx) current))
                (push inner current)))
            (setq idx (1+ idx))))
         (t
          (setq in-token t)
          (push ch current))))
      (setq idx (1+ idx)))
    (when in-token
      (push (apply #'string (nreverse current)) args))
    (nreverse args)))

(defconst chat-command-gate--separator-regexp
  "&&\\|||\\|[;|]"
  "Separators a shell policy may accept between commands.

Only those that run one command after another or pipe one into the next.
Redirection, backgrounding, command substitution and variables are not
here and are refused outright: each of them either writes somewhere the
command's output does not go, or runs something the command does not
name.")

(defconst chat-command-gate--unsafe-regexp
  "[><`$\n\r]"
  "Metacharacters no policy accepts.

Redirection writes where the command's output does not go; backquotes and
`$' run or read something the command does not name.  A lone `&' is
refused too but is not here: it has to be told apart from `&&', which a
shell policy may accept, and one anchored regexp cannot decline the
second character of a pair it declined the first of.  See
`chat-command-gate--lone-ampersand'.")

(defun chat-command-gate--outside-quotes (command regexp)
  "Return the first match position of REGEXP in COMMAND outside quotes.

Quoted text is data.  A refusal triggered by a semicolon inside
`grep \\='a;b\\=' file' would be refusing a search pattern, which is why the
scan tracks quoting instead of matching the raw string."
  (let ((len (length command))
        (idx 0)
        (quote-char nil)
        (found nil))
    (while (and (< idx len) (not found))
      (let ((ch (aref command idx)))
        (cond
         ((and quote-char (eq ch quote-char)) (setq quote-char nil))
         (quote-char nil)
         ((memq ch '(?' ?\")) (setq quote-char ch))
         ((eq ch ?\\) (setq idx (1+ idx)))
         ((let ((case-fold-search nil))
            (and (string-match regexp command idx)
                 (= (match-beginning 0) idx)))
          (setq found idx))))
      (setq idx (1+ idx)))
    found))

(defun chat-command-gate--lone-ampersand (command)
  "Return the position of a backgrounding `&' in COMMAND, outside quotes.

Neither character of `&&' counts.  A background job outlives the tool
call that started it, so it escapes the timeout that was supposed to
bound it and reports to nobody; sequencing with `&&' does neither."
  (let ((len (length command))
        (idx 0)
        (quote-char nil)
        (found nil))
    (while (and (< idx len) (not found))
      (let ((ch (aref command idx)))
        (cond
         ((and quote-char (eq ch quote-char)) (setq quote-char nil))
         (quote-char nil)
         ((memq ch '(?' ?\")) (setq quote-char ch))
         ((eq ch ?\\) (setq idx (1+ idx)))
         ((eq ch ?&)
          (if (or (and (< (1+ idx) len) (eq (aref command (1+ idx)) ?&))
                  (and (> idx 0) (eq (aref command (1- idx)) ?&)))
              (setq idx (1+ idx))
            (setq found idx)))))
      (setq idx (1+ idx)))
    found))

(defun chat-command-gate-segments (command)
  "Split COMMAND on shell separators found outside quotes.

Returns a list of trimmed segment strings.  Separators inside quotes stay
in the segment they belong to."
  (let ((len (length command))
        (idx 0)
        (quote-char nil)
        (start 0)
        (segments nil))
    (while (< idx len)
      (let ((ch (aref command idx)))
        (cond
         ((and quote-char (eq ch quote-char)) (setq quote-char nil))
         (quote-char nil)
         ((memq ch '(?' ?\")) (setq quote-char ch))
         ((eq ch ?\\) (setq idx (1+ idx)))
         ((let ((case-fold-search nil))
            (and (string-match chat-command-gate--separator-regexp command idx)
                 (= (match-beginning 0) idx)))
          (push (substring command start idx) segments)
          (setq idx (1- (match-end 0)))
          (setq start (match-end 0)))))
      (setq idx (1+ idx)))
    (push (substring command start) segments)
    (delq nil
          (mapcar (lambda (segment)
                    (let ((trimmed (string-trim segment)))
                      (unless (string-empty-p trimmed) trimmed)))
                  (nreverse segments)))))

;; ------------------------------------------------------------------
;; Read-only git
;; ------------------------------------------------------------------

(defconst chat-command-gate-git-read-only-subcommands
  '("log" "show" "diff" "status" "rev-parse" "rev-list" "describe" "blame"
    "shortlog" "ls-files" "ls-tree" "cat-file" "for-each-ref" "merge-base"
    "name-rev" "grep" "count-objects" "whatchanged")
  "Git subcommands that cannot change a repository.

Deliberately not a translation of \"the ones people use\".  `config' is
absent because it writes with one flag, `remote' because it takes `add',
and `symbolic-ref' because it moves HEAD when given a second argument --
each looks like a query and is not one.")

(defconst chat-command-gate-git-listing-subcommands
  '("tag" "branch" "stash" "worktree" "remote" "note")
  "Git subcommands that list when asked to and write otherwise.

`git tag' prints tags and `git tag NAME' creates one; the difference is
an argument, not a subcommand, so these are admitted only in the form
that lists.  See `chat-command-gate--git-listing-p'.")

(defconst chat-command-gate-git-listing-flags
  '("-l" "--list" "-v" "--verbose" "-n" "--sort" "--format" "--contains"
    "--no-contains" "--merged" "--no-merged" "--points-at" "--column"
    "--color" "--omit-empty" "-a" "--all" "-r" "--remotes" "--show-current")
  "Flags that put a listing subcommand into its listing form.

`-a' and `-r' are here because `git branch -a' lists; neither creates
anything.  `-a' on `git tag' does create, but only together with a tag
name, and a positional argument is what the listing test refuses.")

(defconst chat-command-gate-git-denied-arguments
  '("--output" "--exec" "--upload-pack" "--receive-pack" "--ext")
  "Argument prefixes that make a read-only git subcommand not read-only.

`git log --output=FILE' writes a file and `--exec' runs a program, so
neither is a query however read-only the subcommand around it is.  This
is the reason the check looks at arguments and not only at the
subcommand.")

(defconst chat-command-gate-git-allowed-options
  '("--no-pager" "--literal-pathspecs")
  "Options accepted before the git subcommand.

`--no-pager' is here because it is the fix for git blocking on a pager
when it has no terminal, which is worth encouraging rather than
tolerating.  `-c' is absent and must stay absent: it sets configuration
for one command, and `-c alias.log=!sh' turns any subcommand on this list
into an arbitrary program.")

(defun chat-command-gate--git-listing-p (arguments)
  "Return non-nil when ARGUMENTS put a listing subcommand in listing form.

Listing form means either no arguments at all -- `git tag' prints tags --
or an explicit listing flag.  A positional argument without one is how
every writing form of these subcommands is spelled."
  (or (null arguments)
      (cl-some (lambda (argument)
                 (cl-some (lambda (flag)
                            (or (equal argument flag)
                                (string-prefix-p (concat flag "=") argument)))
                          chat-command-gate-git-listing-flags))
               arguments)))

(defun chat-command-gate--check-git (argv)
  "Return nil when git ARGV is read-only, or a refusal.

ARGV includes \"git\" itself."
  (let ((rest (cdr argv))
        (refusal nil))
    ;; Options before the subcommand, which is where `-C dir' and
    ;; `--no-pager' legitimately live and where `-c key=value' would
    ;; smuggle in an alias.
    (while (and rest (not refusal) (string-prefix-p "-" (car rest)))
      (let ((option (car rest)))
        (cond
         ((member option chat-command-gate-git-allowed-options)
          (setq rest (cdr rest)))
         ((equal option "-C")
          (setq rest (cddr rest)))
         (t
          (setq refusal
                (chat-command-gate--refuse
                 'git-option option
                 (format "Only %s and -C DIR may precede the subcommand"
                         (string-join chat-command-gate-git-allowed-options
                                      ", "))))))))
    (or refusal
        (let ((subcommand (car rest))
              (arguments (cdr rest)))
          (cond
           ((null subcommand)
            (chat-command-gate--refuse
             'git-subcommand "(none)"
             (format "Name a read-only subcommand: %s"
                     (string-join
                      chat-command-gate-git-read-only-subcommands ", "))))
           ((cl-find-if
             (lambda (argument)
               (cl-some (lambda (denied) (string-prefix-p denied argument))
                        chat-command-gate-git-denied-arguments))
             arguments)
            (chat-command-gate--refuse
             'denied-argument
             (cl-find-if
              (lambda (argument)
                (cl-some (lambda (denied) (string-prefix-p denied argument))
                         chat-command-gate-git-denied-arguments))
              arguments)
             "Read the output from the tool result instead of writing it out"))
           ((member subcommand chat-command-gate-git-read-only-subcommands)
            nil)
           ((member subcommand chat-command-gate-git-listing-subcommands)
            (unless (chat-command-gate--git-listing-p arguments)
              (chat-command-gate--refuse
               'git-writes subcommand
               (format "Use %s with no arguments or with -l to list"
                       subcommand))))
           (t
            (chat-command-gate--refuse
             'git-subcommand subcommand
             (format "Read-only git subcommands are: %s"
                     (string-join
                      chat-command-gate-git-read-only-subcommands ", ")))))))))

;; ------------------------------------------------------------------
;; The decision
;; ------------------------------------------------------------------

(defun chat-command-gate--check-segment (segment commands)
  "Return nil when SEGMENT runs a program in COMMANDS, or a refusal."
  (let* ((argv (chat-command-gate-split segment))
         (program (car argv)))
    (cond
     ((null program)
      (chat-command-gate--refuse 'empty "" nil))
     ((not (member program commands))
      (chat-command-gate--refuse
       'unknown-command program
       (format "Allowed programs: %s" (string-join (sort (copy-sequence commands)
                                                         #'string<)
                                                   ", "))))
     ((equal program "git")
      (chat-command-gate--check-git argv))
     (t nil))))

(cl-defun chat-command-gate-check (command &key commands separators)
  "Return nil when COMMAND may run under this policy, or a refusal.

COMMANDS is the list of programs whose names may start a command.
SEPARATORS, when non-nil, allows `&&', `||', `;' and `|' between
commands, each of which is then checked in turn; when nil, any of them is
refused with a hint to send the commands separately.

That hint is the point of the argument.  A caller that runs one program
through `make-process' cannot honour a pipeline, and saying only \"not
allowed\" about a command containing one leaves the reader unable to tell
that the program was fine and the shape was not -- which is how a working
`git log' gets abandoned along with the `&&' it was chained to."
  (let* ((command (string-trim (or command "")))
         (unsafe (chat-command-gate--outside-quotes
                  command chat-command-gate--unsafe-regexp))
         (ampersand (chat-command-gate--lone-ampersand command))
         (separator (unless separators
                      (chat-command-gate--outside-quotes
                       command chat-command-gate--separator-regexp))))
    (cond
     ((string-empty-p command)
      (chat-command-gate--refuse 'empty "" nil))
     ;; Redirection, substitution and backgrounding, in any policy.
     ((or unsafe ampersand)
      (let ((at (min (or unsafe most-positive-fixnum)
                     (or ampersand most-positive-fixnum))))
        (chat-command-gate--refuse
         'metacharacter (substring command at (1+ at))
         (concat "Redirection, command substitution and background jobs "
                 "are never available"))))
     (separator
      (chat-command-gate--refuse
       'metacharacter
       (save-match-data
         (string-match chat-command-gate--separator-regexp command separator)
         (match-string 0 command))
       "Send each command as its own call; this tool runs one program at a time"))
     (t
      (let ((segments (if separators
                          (chat-command-gate-segments command)
                        (list command)))
            (refusal nil))
        (dolist (segment segments)
          (unless refusal
            (setq refusal (chat-command-gate--check-segment segment commands))))
        refusal)))))

(defun chat-command-gate-describe (commands)
  "Return a sentence naming COMMANDS, for a tool description.

Generated rather than written out.  The description used to be a literal
string listing the same programs, so adding one to the variable left the
description saying it was unavailable -- and a model reads the
description, not the variable."
  (let ((names (sort (copy-sequence commands) #'string<)))
    (concat
     "Available commands: " (string-join names ", ")
     (when (member "git" names)
       (format ". Only read-only git subcommands are available: %s"
               (string-join chat-command-gate-git-read-only-subcommands ", "))))))

;; ------------------------------------------------------------------
;; What a command runs inside
;; ------------------------------------------------------------------

(defconst chat-command-gate-noninteractive-variables
  '("GIT_PAGER=cat"
    "PAGER=cat"
    "TERM=dumb"
    "GIT_TERMINAL_PROMPT=0"
    "GIT_OPTIONAL_LOCKS=0")
  "Environment settings that stop a subprocess waiting for a person.

Every one of these is a way a command can hang forever rather than fail:
a pager waits for a keystroke, git waits for a password, and a tool call
that waits for either has no way to be answered and no way to know that.
`TERM=dumb' also keeps ANSI colour out of the result, which is otherwise
escape codes in the middle of what the model reads.

`GIT_OPTIONAL_LOCKS=0' is the odd one: it keeps a read-only git command
from taking the index lock, so running one cannot make a concurrent
command in the same repository fail.")

(defun chat-command-gate-environment ()
  "Return `process-environment' with interactive behaviour turned off.

Pair this with `:connection-type \\='pipe'.  The variables alone are not
enough on their own account -- they cover the programs we can name, while
the pipe covers the rest by removing the terminal they were checking
for -- and the pipe alone is not enough either, because a forced
`core.pager' does not consult a terminal.

The default is a pty, and that default is what turned admitting `git log'
into admitting a command that blocks for sixty seconds and then reports a
timeout: git saw a terminal, started `less', and `less' printed
\"terminal is not fully functional / Press RETURN to continue\" to a
pipe nobody was reading and waited."
  (append chat-command-gate-noninteractive-variables process-environment))

(provide 'chat-command-gate)
;;; chat-command-gate.el ends here
