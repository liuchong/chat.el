;;; test-chat-command-gate.el --- Tests for chat-command-gate -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: tests

;; This file is not part of GNU Emacs.

;;; Commentary:

;; The one decision about what a model-supplied command may run.
;;
;; Two things are worth testing beyond yes and no.  A refusal has to name
;; the token that failed, because the reason it exists is that "not
;; allowed" left the reader unable to tell which of four rules had closed
;; on them.  And the git rules are per subcommand, so the tests that
;; matter are the pairs: the same subcommand allowed in the form that
;; reads and refused in the form that writes.

;;; Code:

(require 'ert)
(require 'subr-x)
(require 'test-helper)
(require 'chat-command-gate)

(defconst test-chat-command-gate-commands
  '("ls" "cat" "cd" "echo" "grep" "git" "make")
  "A policy's program list, kept small so the tests read as intent.")

(defun test-chat-command-gate-check (command &optional separators)
  "Return the refusal for COMMAND, or nil.  SEPARATORS allows chaining."
  (chat-command-gate-check command
                           :commands test-chat-command-gate-commands
                           :separators separators))

(defun test-chat-command-gate-code (command &optional separators)
  "Return the refusal code for COMMAND, or nil.  SEPARATORS allows chaining."
  (when-let* ((refusal (test-chat-command-gate-check command separators)))
    (chat-command-gate-refusal-code refusal)))

;; ------------------------------------------------------------------
;; A refusal says which token and what to do
;; ------------------------------------------------------------------

(ert-deftest chat-command-gate-a-refusal-names-the-token-that-failed ()
  "The failing word is reported, not just the fact of failure."
  (let ((refusal (test-chat-command-gate-check "rg pattern .")))
    (should refusal)
    (should (eq (chat-command-gate-refusal-code refusal) 'unknown-command))
    (should (equal (chat-command-gate-refusal-token refusal) "rg"))))

(ert-deftest chat-command-gate-a-refusal-says-what-would-work ()
  "Every refusal carries a way forward, which is the point of it.

A refusal that only says no can be answered in one way: abandon the
approach.  That is what happened, for six minutes."
  (dolist (command '("rg pattern ." "git push origin main" "git tag v1"
                     "git log | head" "git -c alias.log=x log"
                     "git log --output=/tmp/x"))
    (let ((refusal (test-chat-command-gate-check command)))
      (should refusal)
      (should (chat-command-gate-refusal-hint refusal))
      (should-not (string-empty-p (chat-command-gate-refusal-hint refusal))))))

(ert-deftest chat-command-gate-an-explanation-carries-token-reason-and-hint ()
  "The sentence a model reads contains all three parts."
  (let* ((refusal (test-chat-command-gate-check "rg pattern ."))
         (text (chat-command-gate-explain refusal "rg pattern .")))
    (should (string-prefix-p "Error:" text))
    (should (string-match-p "rg" text))
    (should (string-match-p "Allowed programs" text))
    ;; The allowed list is generated, so it names what the policy holds.
    (should (string-match-p "git" text))))

(ert-deftest chat-command-gate-a-rejected-chain-is-told-to-split ()
  "A chain names the separator and says to send the parts separately.

The command that started all of this was four commands joined by `&&' and
a pipe.  Told only \"not allowed\", the reader dropped the whole thing,
including the `git log' in the middle that would have worked alone."
  (let ((refusal (test-chat-command-gate-check "cd /tmp && git log")))
    (should (eq (chat-command-gate-refusal-code refusal) 'metacharacter))
    (should (equal (chat-command-gate-refusal-token refusal) "&&"))
    (should (string-match-p "own call"
                            (chat-command-gate-refusal-hint refusal)))))

;; ------------------------------------------------------------------
;; Metacharacters
;; ------------------------------------------------------------------

(ert-deftest chat-command-gate-redirection-is-refused-under-every-policy ()
  "Writing somewhere the result does not go is never available."
  (dolist (command '("echo hi > /tmp/x" "cat < /tmp/x" "echo `whoami`"
                     "echo $HOME"))
    (should (eq (test-chat-command-gate-code command) 'metacharacter))
    (should (eq (test-chat-command-gate-code command t) 'metacharacter))))

(ert-deftest chat-command-gate-a-background-job-is-refused-but-and-is-not ()
  "A lone `&' is backgrounding; `&&' is sequencing.

They differ by one character and by everything else: a background job
outlives the call that started it and answers to no timeout."
  (should (eq (test-chat-command-gate-code "make build &" t) 'metacharacter))
  (should (equal (chat-command-gate-refusal-token
                  (test-chat-command-gate-check "make build &" t))
                 "&"))
  (should-not (test-chat-command-gate-check "make build && make test" t)))

(ert-deftest chat-command-gate-a-separator-inside-quotes-is-data ()
  "A semicolon in a search pattern is not a command separator."
  (should-not (test-chat-command-gate-check "grep 'a;b' file.txt"))
  (should-not (test-chat-command-gate-check "grep \"a|b\" file.txt"))
  (should (eq (test-chat-command-gate-code "grep a;b file.txt")
              'metacharacter)))

(ert-deftest chat-command-gate-a-chaining-policy-checks-every-segment ()
  "Chaining is not a way past the program list."
  (should-not (test-chat-command-gate-check "cd /tmp && git log" t))
  (should (eq (test-chat-command-gate-code "make build && rm -rf /" t)
              'unknown-command))
  (should (eq (test-chat-command-gate-code "git log | rg x" t)
              'unknown-command))
  ;; A refused program anywhere in the chain is reported by name.
  (should (equal (chat-command-gate-refusal-token
                  (test-chat-command-gate-check "cat f && rm x" t))
                 "rm")))

(ert-deftest chat-command-gate-nothing-is-not-a-command ()
  "An empty or blank command is refused rather than run."
  (should (eq (test-chat-command-gate-code "") 'empty))
  (should (eq (test-chat-command-gate-code "   ") 'empty))
  (should (eq (chat-command-gate-refusal-code
               (chat-command-gate-check nil :commands '("ls")))
              'empty)))

;; ------------------------------------------------------------------
;; git, per subcommand
;; ------------------------------------------------------------------

(ert-deftest chat-command-gate-read-only-git-is-allowed ()
  "The subcommands that cannot change a repository pass.

This is the omission that cost the eight minutes: `git log' is as
dangerous as `cat', which was on the list the whole time."
  (dolist (command '("git log --oneline -20"
                     "git log --format=%H%x09%s a..b"
                     "git show HEAD"
                     "git diff --stat"
                     "git status --short"
                     "git rev-parse --abbrev-ref HEAD"
                     "git rev-list --count HEAD"
                     "git describe --always"
                     "git shortlog -sn"
                     "git blame -L 1,10 file.el"
                     "git for-each-ref refs/tags"
                     "git merge-base a b"))
    (should-not (test-chat-command-gate-check command))))

(ert-deftest chat-command-gate-writing-git-is-refused ()
  "A subcommand that can change a repository does not pass as `git'.

This is why the allowance is per subcommand.  Putting the word \"git\" on
a list that matches first words would have admitted every one of these."
  (dolist (command '("git push origin main"
                     "git commit -m x"
                     "git reset --hard HEAD"
                     "git checkout main"
                     "git clean -fd"
                     "git rebase main"
                     "git config user.name x"
                     "git symbolic-ref HEAD refs/heads/x"))
    (should (eq (test-chat-command-gate-code command) 'git-subcommand))
    (should (eq (test-chat-command-gate-code command t) 'git-subcommand))))

(ert-deftest chat-command-gate-a-listing-subcommand-may-list-and-not-write ()
  "`git tag' prints tags and `git tag NAME' creates one.

The difference is an argument, not a subcommand, so the two forms have to
be told apart by their arguments or not at all."
  (should-not (test-chat-command-gate-check "git tag"))
  (should-not (test-chat-command-gate-check "git tag -l"))
  (should-not (test-chat-command-gate-check "git tag -l 'v*'"))
  (should-not (test-chat-command-gate-check "git branch"))
  (should-not (test-chat-command-gate-check "git branch -a"))
  (should (eq (test-chat-command-gate-code "git tag v1.0") 'git-writes))
  (should (eq (test-chat-command-gate-code "git tag -d v1.0") 'git-writes))
  (should (eq (test-chat-command-gate-code "git branch -d topic") 'git-writes))
  (should (eq (test-chat-command-gate-code "git branch topic") 'git-writes)))

(ert-deftest chat-command-gate-a-configuring-option-cannot-precede-a-subcommand ()
  "`git -c' turns any allowed subcommand into an arbitrary program.

`git -c alias.log=!sh log' is spelled as a read-only subcommand and is
not one, which is the reason the options before the subcommand are
checked instead of skipped."
  (should (eq (test-chat-command-gate-code "git -c alias.log=x log")
              'git-option))
  (should (equal (chat-command-gate-refusal-token
                  (test-chat-command-gate-check "git -c core.pager=x log"))
                 "-c"))
  ;; The two that are useful and cannot redirect the subcommand.
  (should-not (test-chat-command-gate-check "git --no-pager log -1"))
  (should-not (test-chat-command-gate-check "git -C /tmp status")))

(ert-deftest chat-command-gate-an-argument-that-writes-is-refused ()
  "A read-only subcommand stops being one when told to write a file."
  (should (eq (test-chat-command-gate-code "git log --output=/tmp/x")
              'denied-argument))
  (should (eq (test-chat-command-gate-code "git diff --output /tmp/x")
              'denied-argument))
  (should (eq (test-chat-command-gate-code
               "git ls-files --exec=/tmp/x")
              'denied-argument)))

(ert-deftest chat-command-gate-git-alone-asks-for-a-subcommand ()
  "The word `git' with nothing after it names no subcommand."
  (should (eq (test-chat-command-gate-code "git") 'git-subcommand))
  (should (string-match-p
           "log"
           (chat-command-gate-refusal-hint
            (test-chat-command-gate-check "git")))))

;; ------------------------------------------------------------------
;; Splitting
;; ------------------------------------------------------------------

(ert-deftest chat-command-gate-quoting-survives-splitting ()
  "One splitter, and it keeps a quoted program intact.

The gate and the runner have to agree about where the words are; a second
tokeniser would approve one command and run another."
  (should (equal (chat-command-gate-split "awk 'BEGIN{print 1}' file")
                 '("awk" "BEGIN{print 1}" "file")))
  (should (equal (chat-command-gate-split "echo \"a b\" c")
                 '("echo" "a b" "c")))
  (should (equal (chat-command-gate-split "echo a\\ b")
                 '("echo" "a b"))))

(ert-deftest chat-command-gate-segments-split-outside-quotes-only ()
  "Segments break on separators that the shell would act on."
  (should (equal (chat-command-gate-segments "cd /tmp && git log")
                 '("cd /tmp" "git log")))
  (should (equal (chat-command-gate-segments "a | b ; c || d")
                 '("a" "b" "c" "d")))
  (should (equal (chat-command-gate-segments "grep 'a;b' f")
                 '("grep 'a;b' f"))))

;; ------------------------------------------------------------------
;; The generated description
;; ------------------------------------------------------------------

(ert-deftest chat-command-gate-a-description-follows-the-list-it-describes ()
  "The description is generated, so it cannot fall behind the variable.

It used to be a literal string naming the same programs, so adding one
left the description saying it was unavailable -- and the description is
the only one of the two a model reads."
  (let ((text (chat-command-gate-describe '("ls" "cat"))))
    (should (string-match-p "ls" text))
    (should (string-match-p "cat" text))
    (should-not (string-match-p "git" text)))
  (let ((text (chat-command-gate-describe '("ls" "git"))))
    (should (string-match-p "read-only git" text))
    ;; And it names them, rather than leaving "read-only" to be guessed.
    (should (string-match-p "rev-parse" text))))

;; ------------------------------------------------------------------
;; What a command runs inside
;; ------------------------------------------------------------------

(ert-deftest chat-command-gate-the-environment-stops-a-command-waiting ()
  "Pagers and credential prompts are told not to wait.

Each of these is a way to hang rather than fail, and a tool call that
hangs cannot be answered by anyone: the pager wanted a keystroke from a
pipe."
  (let ((environment (chat-command-gate-environment)))
    (should (member "GIT_PAGER=cat" environment))
    (should (member "PAGER=cat" environment))
    (should (member "TERM=dumb" environment))
    (should (member "GIT_TERMINAL_PROMPT=0" environment))
    ;; And it extends the environment rather than replacing it, or the
    ;; command would lose PATH and fail to find the program it named.
    (should (> (length environment) (length chat-command-gate-noninteractive-variables)))
    (dolist (entry process-environment)
      (should (member entry environment)))))

(provide 'test-chat-command-gate)
;;; test-chat-command-gate.el ends here
