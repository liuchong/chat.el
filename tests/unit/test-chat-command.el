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

(ert-deftest chat-command-fold-syntax-covers-letters-and-digits ()
  "An input method in fullwidth mode affects the name, not only the slash.

Folding punctuation alone got `／' and left `ｈｅｌｐ', so the command was
not found and the line went to the model as text."
  (should (equal "help" (chat-command-fold-syntax "ｈｅｌｐ")))
  (should (equal "HELP" (chat-command-fold-syntax "ＨＥＬＰ")))
  (should (equal "gpt-4o" (chat-command-fold-syntax "ｇｐｔ－４ｏ"))))

(ert-deftest chat-command-fold-syntax-leaves-cjk-alone ()
  "The fold covers one Unicode block, and ideographs are outside it.

A command named in Chinese has to survive this untouched, and so does
punctuation that belongs to the language rather than to the syntax."
  (should (equal "发送" (chat-command-fold-syntax "发送")))
  (should (equal "。、「」" (chat-command-fold-syntax "。、「」"))))

(ert-deftest chat-command-parse-accepts-any-mix-of-widths ()
  "Prefix and name are folded per character, so mixing them is allowed.

Both halves come from the same keystrokes, and an input method may be
switched mid-word, so no combination of the two can be assumed."
  (dolist (input '("/help" "／help" "/ｈｅｌｐ" "／ｈｅｌｐ"
                   "/ｈeｌp" "／ＨＥＬＰ" "／Ｈelｐ"))
    (let ((parsed (chat-command-parse input)))
      (should (eq 'slash (plist-get parsed :kind)))
      (should (equal "help" (plist-get parsed :name))))))

(ert-deftest chat-command-parse-accepts-fullwidth-prefixes ()
  "Each prefix has a fullwidth form, and the body after it may mix too."
  (should (eq 'shell (plist-get (chat-command-parse "！ls") :kind)))
  (should (eq 'shell-repeat (plist-get (chat-command-parse "！！") :kind)))
  ;; One of each: the two bangs need not agree on width.
  (should (eq 'shell-repeat (plist-get (chat-command-parse "!！") :kind)))
  (should (eq 'query (plist-get (chat-command-parse "？q") :kind)))
  (should (eq 'literal (plist-get (chat-command-parse "＼text") :kind))))

(ert-deftest chat-command-parse-separates-on-a-fullwidth-space ()
  "The space between a name and its argument may be ideographic."
  (let ((parsed (chat-command-parse "／ｈｅｌｐ\u3000queue")))
    (should (equal "help" (plist-get parsed :name)))
    (should (equal "queue" (plist-get parsed :arg)))))

(ert-deftest chat-command-parse-keeps-an-argument-as-typed ()
  "Folding stops at the name.

The same position holds a shell body in one command and a prompt in
another, where a fullwidth character may be exactly what was meant --
searching for fullwidth text, or writing ordinary Chinese."
  (should (equal "grep 中文，测试"
                 (plist-get (chat-command-parse "！grep 中文，测试") :arg)))
  (should (equal "echo ａｂｃ"
                 (plist-get (chat-command-parse "/cmd echo ａｂｃ") :arg)))
  (should (equal "这是什么项目？"
                 (plist-get (chat-command-parse "？这是什么项目？") :arg))))

(ert-deftest chat-command-fold-name-is-for-an-argument-read-as-a-name ()
  "The handler side of the same rule."
  (should (equal "cmd" (chat-command-fold-name "　ｃｍｄ　")))
  (should (equal "off" (chat-command-fold-name "ｏｆｆ")))
  ;; Case is the caller's business.
  (should (equal "KIMI" (chat-command-fold-name "ＫＩＭＩ"))))

(provide 'test-chat-command)
;;; test-chat-command.el ends here
