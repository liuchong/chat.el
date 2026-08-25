;;; test-chat-command.el --- Tests for chat-command.el -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: tests

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Unit tests for chat input command parsing.

;;; Code:

(require 'ert)
(require 'chat-command)

(ert-deftest chat-command-parse-rejects-blank-input ()
  "Blank input carries no command, including a lone ideographic space."
  (should (eq 'empty (plist-get (chat-command-parse "") :kind)))
  (should (eq 'empty (plist-get (chat-command-parse "   ") :kind)))
  (should (eq 'empty (plist-get (chat-command-parse "\u3000") :kind)))
  (should (eq 'empty (plist-get (chat-command-parse nil) :kind))))

(ert-deftest chat-command-parse-reads-shell-prefix-in-both-widths ()
  "Both bang widths introduce a shell command and keep the body as typed."
  (dolist (input '("!ls -l" "！ls -l" "  !  ls -l  "))
    (let ((parsed (chat-command-parse input)))
      (should (eq 'shell (plist-get parsed :kind)))
      (should (equal "ls -l" (plist-get parsed :arg))))))

(ert-deftest chat-command-parse-reads-doubled-bang-as-repeat ()
  "A bare doubled bang repeats history in any width combination."
  (dolist (input '("!!" "！！" "!！" "！!" "  !!  "))
    (should (eq 'shell-repeat (plist-get (chat-command-parse input) :kind))))
  ;; Trailing text means this is a shell body, not a history repeat.
  (let ((parsed (chat-command-parse "!!ls")))
    (should (eq 'shell (plist-get parsed :kind)))
    (should (equal "!ls" (plist-get parsed :arg)))))

(ert-deftest chat-command-parse-reads-query-prefix-in-both-widths ()
  "Both question mark widths introduce an ephemeral AI query."
  (dolist (input '("?why" "？why"))
    (let ((parsed (chat-command-parse input)))
      (should (eq 'query (plist-get parsed :kind)))
      (should (equal "why" (plist-get parsed :arg))))))

(ert-deftest chat-command-parse-reads-slash-name-in-both-widths ()
  "Slash, command name and separator all accept fullwidth forms."
  (dolist (input '("/cd /tmp" "／cd /tmp" "/CD /tmp" "/cd\u3000/tmp"))
    (let ((parsed (chat-command-parse input)))
      (should (eq 'slash (plist-get parsed :kind)))
      (should (equal "cd" (plist-get parsed :name)))
      (should (equal "/tmp" (plist-get parsed :arg))))))

(ert-deftest chat-command-parse-folds-slash-alias-punctuation ()
  "Punctuation-only command names fold to their ASCII spelling."
  (should (equal "!" (plist-get (chat-command-parse "/！ echo hi") :name)))
  (should (equal "!" (plist-get (chat-command-parse "/! echo hi") :name)))
  (should (equal "?" (plist-get (chat-command-parse "/？ why") :name)))
  (should (equal "echo hi" (plist-get (chat-command-parse "/！ echo hi") :arg))))

(ert-deftest chat-command-parse-omits-missing-slash-argument ()
  "A slash command with no argument reports an empty argument."
  (let ((parsed (chat-command-parse "/pwd")))
    (should (equal "pwd" (plist-get parsed :name)))
    (should (equal "" (plist-get parsed :arg)))))

(ert-deftest chat-command-parse-keeps-argument-punctuation-untouched ()
  "Only syntax positions fold, so an argument keeps CJK punctuation.
A shell body or prompt that contains fullwidth characters must reach the
shell or the model exactly as typed."
  (let ((parsed (chat-command-parse "！echo \"你好，世界\"")))
    (should (eq 'shell (plist-get parsed :kind)))
    (should (equal "echo \"你好，世界\"" (plist-get parsed :arg))))
  (let ((parsed (chat-command-parse "？解释 A：B")))
    (should (equal "解释 A：B" (plist-get parsed :arg))))
  (let ((parsed (chat-command-parse "／cmd printf 'A（B）'")))
    (should (equal "cmd" (plist-get parsed :name)))
    (should (equal "printf 'A（B）'" (plist-get parsed :arg)))))

(ert-deftest chat-command-parse-reads-literal-escape ()
  "A leading backslash sends the rest verbatim so prefixes can be typed."
  (dolist (input '("\\!not a command" "＼!not a command"))
    (let ((parsed (chat-command-parse input)))
      (should (eq 'literal (plist-get parsed :kind)))
      (should (equal "!not a command" (plist-get parsed :arg))))))

(ert-deftest chat-command-parse-treats-plain-text-as-note ()
  "Text without a command prefix stays an ordinary message."
  (let ((parsed (chat-command-parse "  hello there  ")))
    (should (eq 'note (plist-get parsed :kind)))
    (should (equal "hello there" (plist-get parsed :arg))))
  ;; A lone fullwidth tilde is prose, not a command prefix.
  (should (eq 'note (plist-get (chat-command-parse "～") :kind))))

(ert-deftest chat-command-fold-syntax-covers-documented-pairs ()
  "Every documented punctuation pair folds to its ASCII counterpart."
  (should (equal "!?/\\~:,;()[]{}\"' "
                 (chat-command-fold-syntax "！？／＼～：，；（）［］｛｝＂＇\u3000")))
  (should (equal "abc" (chat-command-fold-syntax "abc"))))

(ert-deftest chat-command-fold-path-folds-only-slash-and-tilde ()
  "Path folding covers separators without rewriting a directory name."
  (should (equal "~/tmp" (chat-command-fold-path "～／tmp")))
  (should (equal "/tmp/a，b" (chat-command-fold-path "／tmp／a，b"))))

(provide 'test-chat-command)
;;; test-chat-command.el ends here
