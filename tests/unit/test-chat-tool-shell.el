;;; test-chat-tool-shell.el --- Tests for chat-tool-shell -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: tests

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Unit tests for the built in shell tool registration.

;;; Code:

(require 'ert)
(require 'subr-x)
(require 'test-helper)
(require 'chat-code)
(require 'chat-tool-shell)

(ert-deftest chat-tool-shell-is-registered-active ()
  "Test that the built in shell tool is active after registration."
  (let ((tool (chat-tool-forge-get 'shell_execute)))
    (should tool)
    (should (chat-forged-tool-is-active tool))
    (should (equal (chat-forged-tool-parameters tool)
                   '((:name "command" :type "string" :required t)
                     (:name "timeout" :type "number" :required nil))))))

(ert-deftest chat-tool-shell-allows-directory-size-command ()
  "Test that common directory inspection commands are allowed."
  (should (chat-tool-shell-validate "du -sh ~/Downloads"))
  (should (chat-tool-shell-validate "find . -type d")))

(ert-deftest chat-tool-shell-rejects-shell-metacharacters ()
  "Test that shell metacharacters are rejected."
  (should-not (chat-tool-shell-validate "find . -type d | wc -l"))
  (should-not (chat-tool-shell-validate "echo ok; rm -rf /tmp/demo")))

(ert-deftest chat-tool-shell-executes-without-shell-expansion ()
  "Test shell tool uses argv execution for safe commands."
  (let ((chat-tool-shell-enabled t))
    (should (string= (string-trim (chat-tool-shell-execute "echo hello")) "hello"))))

(ert-deftest chat-tool-shell-whitelist-includes-common-readonly-commands ()
  "Test builtin whitelist covers common readonly exploration commands."
  (should (chat-tool-shell-whitelist-match-p "pwd"))
  (should (chat-tool-shell-whitelist-match-p "ls -la"))
  (should (chat-tool-shell-whitelist-match-p "find . -type f")))

(ert-deftest chat-tool-shell-executes-safe-cd-prefix ()
  "Test shell tool supports a safe `cd DIR && CMD` form."
  (chat-test-with-temp-dir
   (let ((chat-tool-shell-enabled t)
         (chat-files-allowed-directories (list temp-dir)))
     (should (string= (string-trim
                       (chat-tool-shell-execute
                        (format "cd %s && pwd" (shell-quote-argument temp-dir))))
                      (file-truename temp-dir))))))

(ert-deftest chat-tool-shell-split-preserves-single-quoted-args ()
  "Test that single-quoted arguments survive command splitting."
  (should (equal (chat-tool-shell--split-command
                  "awk 'BEGIN{system(\"touch /tmp/x\")}' /etc/hostname")
                 '("awk" "BEGIN{system(\"touch /tmp/x\")}" "/etc/hostname")))
  (should (equal (chat-tool-shell--split-command
                  "sed -i -e 's/a/b/' file")
                 '("sed" "-i" "-e" "s/a/b/" "file"))))

(ert-deftest chat-tool-shell-split-handles-quotes-and-escapes ()
  "Test that double quotes and backslash escapes group arguments."
  (should (equal (chat-tool-shell--split-command "echo \"a b\" c")
                 '("echo" "a b" "c")))
  (should (equal (chat-tool-shell--split-command "ls -la /tmp")
                 '("ls" "-la" "/tmp")))
  (should (equal (chat-tool-shell--split-command "echo a\\ b")
                 '("echo" "a b"))))

(ert-deftest chat-tool-shell-reports-nonzero-exit-status ()
  "Test failing commands return output with an exit status note."
  (let ((result (chat-tool-shell--execute-argv "ls /nonexistent-dir-xyz")))
    (should (string-match-p "\\[exit status [0-9]+\\]" result))
    (should (string-match-p "\\[stderr\\]" result))))

(ert-deftest chat-tool-shell-enforces-timeout ()
  "Test commands running past the timeout are killed and reported."
  (let ((result (chat-tool-shell--execute-argv "sleep 5" 1)))
    (should (string-match-p "\\[timed out after 1 seconds\\]" result))))

(ert-deftest chat-tool-shell-truncates-long-output-with-spill-file ()
  "Test oversized output is truncated and spills into a file."
  (let ((chat-tool-shell-output-max-lines 3)
        (chat-tool-shell-output-max-chars 50000))
    (let ((result (chat-tool-shell--execute-argv "seq 1 10")))
      (should (string-match-p "1\n2\n3" result))
      (should-not (string-match-p "\n9\n" result))
      (should (string-match-p "\\[output truncated:" result))
      (let ((path (and (string-match "saved to \\([^]]+\\)\\]" result)
                       (match-string 1 result))))
        (should path)
        (should (file-exists-p path))
        (with-temp-buffer
          (insert-file-contents path)
          (should (string-match-p "\n10" (buffer-string))))))))

;; ------------------------------------------------------------------
;; Read-only git, and why a refusal has to say more than no
;; ------------------------------------------------------------------

(ert-deftest chat-tool-shell-runs-read-only-git ()
  "Reading a repository's history is available through the shell tool.

It was not, for no reason anyone recorded, and the cost was an agent
spending six minutes trying to recover commit subjects from zlib-
compressed objects with `cat' and `grep' -- a route that cannot work,
attempted because the only route that could was closed."
  (should (chat-tool-shell-validate "git log --oneline -20"))
  (should (chat-tool-shell-validate "git rev-parse --abbrev-ref HEAD"))
  (should (chat-tool-shell-validate "git status --short"))
  (should (chat-tool-shell-validate "git tag -l"))
  (should (chat-tool-shell-validate "git describe --always")))

(ert-deftest chat-tool-shell-refuses-git-that-would-write ()
  "The allowance is per subcommand, so writing forms stay refused.

Adding the word \"git\" to the program list would have been a one-line
change and would have admitted `git push --force' with it, because the
list matches first words."
  (should-not (chat-tool-shell-validate "git push origin main"))
  (should-not (chat-tool-shell-validate "git commit -m x"))
  (should-not (chat-tool-shell-validate "git reset --hard HEAD"))
  (should-not (chat-tool-shell-validate "git checkout main"))
  (should-not (chat-tool-shell-validate "git tag v1.0")))

(ert-deftest chat-tool-shell-a-refusal-explains-itself ()
  "The result of a refused command names the token, reason and remedy.

The old result was the words \"Command not allowed\" and a copy of the
command.  For a command that joined four `git' calls with `&&' and a
pipe, that single sentence covered an unlisted program, two rejected
metacharacters and a quoting question equally well, so it distinguished
none of them -- and the reader abandoned `git' entirely rather than
retrying one call at a time."
  (let ((chat-tool-shell-enabled t))
    (let ((result (chat-tool-shell-execute "git push origin main")))
      (should (string-prefix-p "Error:" result))
      (should (string-match-p "push" result))
      (should (string-match-p "read-only" result))
      ;; And it names the ones that do work, so the next attempt is informed.
      (should (string-match-p "rev-parse" result)))
    (let ((result (chat-tool-shell-execute "unknown-program --help")))
      (should (string-match-p "unknown-program" result))
      (should (string-match-p "Allowed programs" result)))))

(ert-deftest chat-tool-shell-a-refused-chain-is-told-about-the-cd-prefix ()
  "A rejected `&&' does not imply there is no way to choose a directory.

The tool accepts one `cd DIR && COMMAND' prefix, which the gate does not
know about, so the tool says so rather than leaving the reader with a
rule that is stricter than the truth."
  (let ((chat-tool-shell-enabled t))
    (let ((result (chat-tool-shell-execute
                   "cd /tmp && git rev-parse HEAD && git log -1")))
      (should (string-match-p "own call" result))
      (should (string-match-p "cd DIR" result)))))

(ert-deftest chat-tool-shell-read-only-git-does-not-wait-for-a-pager ()
  "A git command that would page finishes instead of timing out.

Emacs gives a subprocess a pty by default, git seeing a terminal starts a
pager, and the pager waits for a keystroke that cannot arrive through a
pipe.  Untreated, admitting `git log' admitted a command that reports a
timeout sixty seconds after doing its work: the task log from the
incident contains `less' saying \"Press RETURN to continue\" and nothing
else."
  (let ((result (chat-tool-shell--execute-argv "git log -1 --format=%H" 10)))
    (should-not (string-match-p "timed out" result))
    (should-not (string-match-p "Press RETURN" result))
    (should (string-match-p "\\`[0-9a-f]\\{40\\}" (string-trim result)))))

(ert-deftest chat-tool-shell-the-description-lists-what-is-allowed ()
  "The description is generated from the program list, not written out.

Written out, the two drift -- and the description is the only one of them
a model reads, so the drift is invisible until a model declines to use a
command that works."
  (let ((tool (chat-tool-forge-get 'shell_execute)))
    (should tool)
    (let ((description (chat-forged-tool-description tool)))
      (dolist (program chat-tool-shell-allowed-commands)
        (should (string-match-p (regexp-quote program) description)))
      (should (string-match-p "read-only git" description))
      ;; And the shape restriction, which is what the incident hit first.
      (should (string-match-p "cd DIR" description)))))

(provide 'test-chat-tool-shell)
;;; test-chat-tool-shell.el ends here
