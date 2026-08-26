;;; test-chat-i18n.el --- Language of what the user reads -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: tests

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Two things are worth testing here and they are different.
;;
;; One is the mechanism: resolution, fallback, formatting.  A missing key
;; must degrade to readable English rather than to blank, because a
;; half-finished catalog is the normal state of a catalog.
;;
;; The other is that a translation stays in step with what it translates.
;; The help text names keys and slash commands, and a translation that
;; drops one describes a program that does not exist.  That is checked
;; against the English text rather than against a list, so the check
;; cannot go stale.

;;; Code:

(require 'ert)
(require 'test-helper)
(require 'chat-i18n)
(require 'chat)

;; ------------------------------------------------------------------
;; Resolution
;; ------------------------------------------------------------------

(ert-deftest chat-i18n-an-explicit-language-wins ()
  "Setting the language means it, whatever the machine says."
  (let ((chat-language 'zh-CN))
    (should (eq (chat-i18n-language) 'zh-CN)))
  (let ((chat-language 'en))
    (should (eq (chat-i18n-language) 'en))))

(ert-deftest chat-i18n-auto-reads-the-environment ()
  "`auto' takes what the user already set for everything else."
  (let ((chat-language 'auto)
        (current-language-environment "Chinese-GB18030"))
    (should (eq (chat-i18n-language) 'zh-CN)))
  (let ((chat-language 'auto)
        (current-language-environment "English"))
    (should (eq (chat-i18n-language) 'en))))

(ert-deftest chat-i18n-auto-falls-back-to-the-locale-variables ()
  "Not every Emacs has a language environment set."
  (let ((chat-language 'auto)
        (current-language-environment nil)
        (process-environment (cons "LANG=zh_CN.UTF-8" process-environment)))
    (should (eq (chat-i18n-language) 'zh-CN))))

(ert-deftest chat-i18n-an-unknown-locale-is-english ()
  "A language with no catalog reads as English, not as nothing."
  (let ((chat-language 'auto)
        (current-language-environment "Klingon"))
    (should (eq (chat-i18n-language) 'en))))

;; ------------------------------------------------------------------
;; Lookup and fallback
;; ------------------------------------------------------------------

(ert-deftest chat-i18n-a-missing-key-reads-as-english ()
  "A half-finished catalog is the normal state of a catalog."
  (let ((chat-language 'zh-CN))
    (should (equal (chat-i18n 'no-such-key-anywhere "the English text")
                   "the English text"))))

(ert-deftest chat-i18n-a-translated-key-reads-as-the-translation ()
  (let ((chat-language 'zh-CN))
    (should-not (equal (chat-i18n 'help-text chat-commands-help)
                       chat-commands-help))))

(ert-deftest chat-i18n-formats-its-arguments ()
  "A catalog entry is a format string, in whichever language."
  (let ((chat-language 'en))
    (should (equal (chat-i18n 'no-such-key "ran /%s twice" "cmd")
                   "ran /cmd twice")))
  (let ((chat-language 'zh-CN))
    (should (string-match-p "cmd" (chat-i18n 'auto-claimed "fallback %s" "cmd")))))

(ert-deftest chat-i18n-register-adds-and-replaces ()
  "A catalog is assembled by the modules that own the strings."
  (let ((chat-i18n-catalogs (copy-tree chat-i18n-catalogs)))
    (chat-i18n-register 'zh-CN '((probe-key . "first")))
    (should (equal (chat-i18n-lookup 'probe-key 'zh-CN) "first"))
    (chat-i18n-register 'zh-CN '((probe-key . "second")))
    (should (equal (chat-i18n-lookup 'probe-key 'zh-CN) "second"))))

(ert-deftest chat-i18n-register-can-open-a-new-language ()
  (let ((chat-i18n-catalogs (copy-tree chat-i18n-catalogs)))
    (chat-i18n-register 'ja '((probe-key . "テスト")))
    (should (equal (chat-i18n-lookup 'probe-key 'ja) "テスト"))))

;; ------------------------------------------------------------------
;; Coverage is a number, not a feeling
;; ------------------------------------------------------------------

(ert-deftest chat-i18n-coverage-counts-what-is-missing ()
  (let ((chat-i18n-catalogs '((en . nil) (zh-CN . ((a . "1") (b . "2"))))))
    (should (= (chat-i18n-coverage 'zh-CN) 1.0))
    (should (equal (chat-i18n-missing-keys 'zh-CN) nil)))
  (let ((chat-i18n-catalogs '((en . ((a . "1") (b . "2") (c . "3")))
                              (zh-CN . ((a . "one"))))))
    (should (equal (chat-i18n-missing-keys 'zh-CN) '(b c)))
    (should (< (chat-i18n-coverage 'zh-CN) 0.5))))

(ert-deftest chat-i18n-english-is-complete-by-definition ()
  "Its text lives at the call sites, so an empty catalog is not a gap.

Reporting English as 0% translated would be reporting that nothing reads
as English, which is backwards."
  (should (= (chat-i18n-coverage 'en) 1.0)))

(ert-deftest chat-i18n-the-shipped-chinese-catalog-is-complete ()
  "Every key some catalog defines has a Chinese entry.

This is the one shipped translation, so a key added without translating
it should fail here rather than surface as English in a Chinese session."
  (should-not (chat-i18n-missing-keys 'zh-CN)))

(ert-deftest chat-i18n-the-literal-escape-is-not-doubled ()
  "The help shows what you type, and `\\\\<text>' is not what you type."
  (let ((translated (chat-i18n-lookup 'help-text 'zh-CN)))
    (should (string-match-p "\\\\<" translated))
    (should-not (string-match-p "\\\\\\\\<" translated))))

;; ------------------------------------------------------------------
;; A translation has to describe the program that exists
;; ------------------------------------------------------------------

(defun chat-i18n-test--keys-in (text)
  "Return the key sequences TEXT names, using the help extraction rules."
  (let ((chat-commands-help text))
    (sort (chat-test--help-keys) #'string<)))

(defun chat-i18n-test--slash-names-in (text)
  "Return the slash command names TEXT names."
  (let ((chat-commands-help text))
    (sort (chat-test--help-slash-names) #'string<)))

(ert-deftest chat-i18n-the-translated-help-names-the-same-keys ()
  "A translation that drops a key documents a program that is not this one.

Checked against the English text rather than a hand-kept list, so the
check cannot go stale as the help changes."
  (let ((translated (chat-i18n-lookup 'help-text 'zh-CN)))
    (should translated)
    (should (equal (chat-i18n-test--keys-in translated)
                   (chat-i18n-test--keys-in chat-commands-help)))))

(ert-deftest chat-i18n-the-translated-help-names-the-same-commands ()
  "Command names are what you type, so they stay in ASCII and stay whole."
  (let ((translated (chat-i18n-lookup 'help-text 'zh-CN)))
    (should translated)
    (should (equal (chat-i18n-test--slash-names-in translated)
                   (chat-i18n-test--slash-names-in chat-commands-help)))))

(ert-deftest chat-i18n-the-translated-help-is-actually-translated ()
  "A copy of the English text would pass every check above."
  (let ((translated (chat-i18n-lookup 'help-text 'zh-CN)))
    (should (string-match-p "[一-龥]" translated))
    ;; And it is not a token gesture: the prose is translated too, not
    ;; just a heading over English text.
    (should-not (string-match-p "Type your message and press RET" translated))
    (should-not (string-match-p "Shell work comes in runs" translated))))

(ert-deftest chat-help-text-follows-the-language ()
  "The surface shows the catalog entry, not the English constant."
  (let ((chat-language 'zh-CN))
    (should (equal (chat-help-text) (chat-i18n-lookup 'help-text 'zh-CN))))
  (let ((chat-language 'en))
    (should (equal (chat-help-text) chat-commands-help))))

(provide 'test-chat-i18n)
;;; test-chat-i18n.el ends here
