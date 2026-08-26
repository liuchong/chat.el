;;; test-chat-shell-builtins.el --- Tests for shell builtins -*- lexical-binding: t -*-

;;; Commentary:

;; The builtins here exist because a subprocess cannot change its parent.
;; These tests hold that line: what must be interpreted in Lisp is, what
;; belongs to the shell reaches the shell, and a compound command is never
;; swallowed halfway.

;;; Code:

(require 'ert)
(require 'chat-shell-builtins)

;; ------------------------------------------------------------------
;; What counts as a builtin
;; ------------------------------------------------------------------

(ert-deftest chat-shell-builtins-recognises-the-directory-commands ()
  "Each directory builtin parses, with its argument."
  (should (equal '(:builtin cd :arg "/tmp")
                 (chat-shell-builtins-parse "cd /tmp")))
  (should (equal '(:builtin cd :arg "")
                 (chat-shell-builtins-parse "cd")))
  (should (equal '(:builtin cd :arg "-")
                 (chat-shell-builtins-parse "cd -")))
  (should (equal '(:builtin pushd :arg "/tmp")
                 (chat-shell-builtins-parse "pushd /tmp")))
  (should (equal '(:builtin popd) (chat-shell-builtins-parse "popd")))
  (should (equal '(:builtin dirs) (chat-shell-builtins-parse "dirs"))))

(ert-deftest chat-shell-builtins-recognises-the-environment-commands ()
  "Export and unset parse with the text after the command name."
  (should (equal '(:builtin export :arg "FOO=bar")
                 (chat-shell-builtins-parse "export FOO=bar")))
  (should (equal '(:builtin unset :arg "FOO")
                 (chat-shell-builtins-parse "unset FOO"))))

(ert-deftest chat-shell-builtins-leaves-a-compound-command-to-the-shell ()
  "A line with metacharacters is not ours, so it parses as no builtin.

Interpreting the `cd' half of `cd /tmp && ls' would run the first part
here and drop the second, which is worse than not intercepting at all."
  (should-not (chat-shell-builtins-parse "cd /tmp && ls"))
  (should-not (chat-shell-builtins-parse "cd /tmp; ls"))
  (should-not (chat-shell-builtins-parse "export FOO=$(id -u)"))
  (should-not (chat-shell-builtins-parse "pushd /tmp | cat")))

(ert-deftest chat-shell-builtins-does-not-claim-a-command-that-merely-starts-alike ()
  "A longer name that begins with a builtin's name is a different command."
  (should-not (chat-shell-builtins-parse "cdate"))
  (should-not (chat-shell-builtins-parse "exportfs"))
  (should-not (chat-shell-builtins-parse "dirshow"))
  (should-not (chat-shell-builtins-parse "ls")))

;; ------------------------------------------------------------------
;; cd -
;; ------------------------------------------------------------------

(ert-deftest chat-shell-builtins-a-bare-cd-means-home ()
  "As in a shell."
  (should (equal "~" (chat-shell-builtins-resolve-directory "")))
  (should (equal "~" (chat-shell-builtins-resolve-directory nil))))

(ert-deftest chat-shell-builtins-cd-dash-returns-to-where-we-were ()
  "The dash resolves to the recorded previous directory, not a path named `-'.

`expand-file-name' turns `-' into a relative path under the current
directory, which is how `cd -' came to report a missing directory."
  (with-temp-buffer
    (chat-shell-builtins-record-departure "/tmp/")
    (should (equal "/tmp/" (chat-shell-builtins-resolve-directory "-")))))

(ert-deftest chat-shell-builtins-cd-dash-says-so-when-there-is-nowhere-to-go ()
  "With no previous directory the dash reports an error rather than a path."
  (with-temp-buffer
    (setq chat-shell-previous-directory nil)
    (let ((result (chat-shell-builtins-resolve-directory "-")))
      (should (eq (car-safe result) 'error))
      (should (string-match-p "OLDPWD\\|上一个" (cdr result))))))

;; ------------------------------------------------------------------
;; The directory stack
;; ------------------------------------------------------------------

(ert-deftest chat-shell-builtins-the-directory-stack-is-last-in-first-out ()
  "Pushed directories come back in reverse order, then the stack is empty."
  (with-temp-buffer
    (setq chat-shell-directory-stack nil)
    (chat-shell-builtins-push-directory "/one/")
    (chat-shell-builtins-push-directory "/two/")
    (should (equal "/two/" (chat-shell-builtins-pop-directory)))
    (should (equal "/one/" (chat-shell-builtins-pop-directory)))
    (should-not (chat-shell-builtins-pop-directory))))

(ert-deftest chat-shell-builtins-the-stack-report-puts-the-current-directory-first ()
  "As `dirs' does, with the home directory abbreviated."
  (with-temp-buffer
    (setq chat-shell-directory-stack '("/one/" "/two/"))
    (should (equal "/here /one /two"
                   (chat-shell-builtins-directory-stack-report "/here/")))))

;; ------------------------------------------------------------------
;; Exported variables
;; ------------------------------------------------------------------

(ert-deftest chat-shell-builtins-an-assignment-splits-at-the-first-equals ()
  "A value may itself contain an equals sign."
  (should (equal '("FOO" . "bar")
                 (chat-shell-builtins-parse-assignment "FOO=bar")))
  (should (equal '("FOO" . "a=b")
                 (chat-shell-builtins-parse-assignment "FOO=a=b")))
  (should (equal '("FOO" . "")
                 (chat-shell-builtins-parse-assignment "FOO="))))

(ert-deftest chat-shell-builtins-an-assignment-loses-one-layer-of-quotes ()
  "The quotes are shell syntax, not part of the value."
  (should (equal '("FOO" . "a b")
                 (chat-shell-builtins-parse-assignment "FOO=\"a b\"")))
  (should (equal '("FOO" . "a b")
                 (chat-shell-builtins-parse-assignment "FOO='a b'"))))

(ert-deftest chat-shell-builtins-rejects-a-name-that-is-not-one ()
  "A name that a shell would refuse is refused here too."
  (should-not (chat-shell-builtins-parse-assignment "1FOO=bar"))
  (should-not (chat-shell-builtins-parse-assignment "FOO BAR=baz")))

(ert-deftest chat-shell-builtins-setting-a-variable-twice-keeps-the-last-value ()
  "Otherwise the environment would carry both and the first would win."
  (with-temp-buffer
    (setq chat-shell-environment nil)
    (chat-shell-builtins-set-variable "FOO" "one")
    (chat-shell-builtins-set-variable "FOO" "two")
    (should (equal '(("FOO" . "two")) chat-shell-environment))))

(ert-deftest chat-shell-builtins-unset-forgets-a-variable ()
  "And leaves the others alone."
  (with-temp-buffer
    (setq chat-shell-environment nil)
    (chat-shell-builtins-set-variable "FOO" "one")
    (chat-shell-builtins-set-variable "BAR" "two")
    (chat-shell-builtins-unset-variable "FOO")
    (should (equal '(("BAR" . "two")) chat-shell-environment))))

(ert-deftest chat-shell-builtins-an-export-reaches-the-next-command ()
  "The exported variable is in the environment a later command runs with.

Each command is its own subshell, so without this an export would reach
only the process that performed it -- the variable would look set and
then not be."
  (with-temp-buffer
    (setq chat-shell-environment nil)
    (chat-shell-builtins-set-variable "CHAT_TEST_VAR" "present")
    (let ((process-environment (chat-shell-builtins-process-environment)))
      (should (equal "present" (getenv "CHAT_TEST_VAR"))))))

(ert-deftest chat-shell-builtins-an-export-shadows-an-inherited-value ()
  "What was set here wins over what the environment already had."
  (with-temp-buffer
    (setq chat-shell-environment nil)
    (chat-shell-builtins-set-variable "CHAT_TEST_VAR" "mine")
    (let ((process-environment
           (chat-shell-builtins-process-environment)))
      (should (equal "mine" (getenv "CHAT_TEST_VAR")))))
  (let ((process-environment (cons "CHAT_TEST_VAR=inherited" process-environment)))
    (with-temp-buffer
      (setq chat-shell-environment nil)
      (chat-shell-builtins-set-variable "CHAT_TEST_VAR" "mine")
      (let ((process-environment (chat-shell-builtins-process-environment)))
        (should (equal "mine" (getenv "CHAT_TEST_VAR")))))))

(ert-deftest chat-shell-builtins-two-buffers-keep-separate-environments ()
  "The environment belongs to the session, as the working directory does."
  (let (first second)
    (with-temp-buffer
      (setq chat-shell-environment nil)
      (chat-shell-builtins-set-variable "FOO" "one")
      (setq first chat-shell-environment))
    (with-temp-buffer
      (setq chat-shell-environment nil)
      (chat-shell-builtins-set-variable "FOO" "two")
      (setq second chat-shell-environment))
    (should (equal '(("FOO" . "one")) first))
    (should (equal '(("FOO" . "two")) second))))

(provide 'test-chat-shell-builtins)
;;; test-chat-shell-builtins.el ends here
