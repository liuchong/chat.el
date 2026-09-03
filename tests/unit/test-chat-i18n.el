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
(require 'cl-lib)
(require 'test-helper)
(require 'chat-i18n)
(require 'chat)
(require 'chat-code)

;; ------------------------------------------------------------------
;; Resolution
;; ------------------------------------------------------------------

(ert-deftest chat-i18n-an-explicit-language-wins ()
  "Setting the language means it, whatever the machine says."
  (let ((chat-language 'zh-CN))
    (should (eq (chat-i18n-language) 'zh-CN)))
  (let ((chat-language 'en))
    (should (eq (chat-i18n-language) 'en))))

(ert-deftest chat-i18n-an-explicit-language-is-alias-normalized ()
  "A user who writes 'zh-cn or \"zh_CN\" means the zh-CN catalog.
The catalogs are keyed zh-CN; the setting is not the place to learn that
casing."
  (let ((chat-language 'zh-cn))
    (should (eq (chat-i18n-language) 'zh-CN)))
  (let ((chat-language "zh_CN.UTF-8"))
    (should (eq (chat-i18n-language) 'zh-CN))))

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
    (should-not (string-match-p "In the chat buffer, type a message" translated))
    (should-not (string-match-p "Plain input runs through one command" translated))))

;; ------------------------------------------------------------------
;; Command names
;; ------------------------------------------------------------------

(ert-deftest chat-i18n-a-translated-command-name-reaches-the-handler ()
  "`/自动' and `/auto' are one command, so it is declared once."
  (should (equal (chat-i18n-resolve-alias "自动") "auto"))
  (should (eq (chat-ui--command-handler "自动")
              (chat-ui--command-handler "auto")))
  (should (eq (chat-ui--command-handler "发送")
              (chat-ui--command-handler "send")))
  ;; Including the properties, which is the reason for resolving rather
  ;; than for a second table.
  (should (chat-ui--command-repeatable-p "命令"))
  (should (eq (chat-ui--command-default-effect "快问") 'reset)))

(ert-deftest chat-i18n-a-translated-name-parses-and-dispatches ()
  "The whole path, not just the lookup: parse, resolve, run."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-session-create "Alias" 'kimi))
          (shell-calls nil))
     (with-temp-buffer
       (setq-local chat--current-session session)
       (chat-ui-setup-buffer session)
       (cl-letf (((symbol-function 'chat-ui--handle-shell-command)
                  (lambda (command) (push command shell-calls))))
         (chat-ui--dispatch-command (chat-command-parse "/命令 ls"))
         (should (equal shell-calls '("ls")))
         ;; And it claimed plain input under its canonical name, so the
         ;; state does not depend on which spelling was typed.
         (should (equal (chat-ui-default-command) "cmd")))))))

(ert-deftest chat-i18n-an-alias-is-accepted-whatever-the-language ()
  "Refusing a name the user knows, to be consistent about locale, is
pedantry with no upside."
  (let ((chat-language 'en))
    (should (eq (chat-ui--command-handler "自动")
                (chat-ui--command-handler "auto")))))

(ert-deftest chat-i18n-no-alias-shadows-a-command ()
  "An alias that collided with a real name would silently redirect it."
  (dolist (catalog chat-i18n-aliases)
    (dolist (alias (cdr catalog))
      (should-not (seq-find (lambda (entry)
                              (equal (plist-get entry :name) (car alias)))
                            chat-ui--command-table))
      ;; And it has to point at something that exists.
      (should (seq-find (lambda (entry)
                          (equal (plist-get entry :name) (cdr alias)))
                        chat-ui--command-table)))))

(ert-deftest chat-i18n-an-alias-name-has-no-whitespace ()
  "A name is read up to the first space, so one with a space in it could
never be typed."
  (dolist (catalog chat-i18n-aliases)
    (dolist (alias (cdr catalog))
      (should-not (string-match-p "[ \t\u3000]" (car alias))))))

(ert-deftest chat-i18n-completion-offers-the-language-in-use ()
  "Every alias at once would be a list that is mostly noise."
  (let ((chat-language 'zh-CN))
    (let ((offered (chat-ui--command-completion-table)))
      (should (member "自动" offered))
      (should-not (member "auto" offered))))
  (let ((chat-language 'en))
    (let ((offered (chat-ui--command-completion-table)))
      (should (member "auto" offered))
      (should-not (member "自动" offered)))))

(ert-deftest chat-i18n-the-shipped-aliases-cover-every-command ()
  "A half-translated command list is worse than an English one: the
reader cannot tell which names have a translation and which do not."
  (let (untranslated)
    (dolist (entry chat-ui--command-table)
      (let ((name (plist-get entry :name)))
        (unless (chat-i18n-localized-name name 'zh-CN)
          (push name untranslated))))
    (should-not untranslated)))

(ert-deftest chat-i18n-the-first-alias-declared-is-the-one-offered ()
  "Where a command has two names, which one is shown is not arbitrary.

Built with `push', the list handed back whichever synonym happened to be
declared last -- which is how `提问' came to be offered for /send in place
of `发送'."
  (should (equal (chat-i18n-localized-name "send" 'zh-CN) "发送"))
  (let ((chat-i18n-aliases (copy-tree chat-i18n-aliases)))
    (chat-i18n-register-aliases 'probe-lang '(("first" . "send")
                                              ("second" . "send")))
    (should (equal (chat-i18n-localized-name "send" 'probe-lang) "first"))
    ;; Re-registering replaces in place rather than shuffling the order.
    (chat-i18n-register-aliases 'probe-lang '(("first" . "send")))
    (should (equal (chat-i18n-localized-name "send" 'probe-lang) "first"))))

(ert-deftest chat-i18n-english-aliases-are-spellings-not-translations ()
  "`?' is another way to write `/quick', so completion still offers
`quick': the canonical name is the one the rest of the surface uses."
  (should (equal (chat-i18n-resolve-alias "?") "quick"))
  (should-not (chat-i18n-localized-name "quick" 'en))
  (let ((chat-language 'en))
    (should (equal (chat-ui--display-command-name "quick") "quick"))))

;; ------------------------------------------------------------------
;; What the model is told
;; ------------------------------------------------------------------

(ert-deftest chat-reply-language-follows-the-interface-by-default ()
  (let ((chat-reply-language 'follow)
        (chat-language 'zh-CN))
    (should (equal (chat-reply-language-name) "Simplified Chinese")))
  (let ((chat-reply-language 'follow)
        (chat-language 'en))
    (should (equal (chat-reply-language-name) "English"))))

(ert-deftest chat-reply-language-can-be-pinned-or-silenced ()
  "A language with no catalog can still be asked for; nil says nothing."
  (let ((chat-reply-language 'en)
        (chat-language 'zh-CN))
    (should (equal (chat-reply-language-name) "English")))
  (let ((chat-reply-language "Japanese"))
    (should (equal (chat-reply-language-name) "Japanese")))
  (let ((chat-reply-language nil))
    (should-not (chat-reply-language-name))))

(ert-deftest chat-reply-language-reaches-the-system-prompt ()
  "Stated to the model rather than inferred from how the user phrased it."
  (let ((chat-reply-language 'zh-CN))
    (let ((prompt (chat-tool-caller-build-system-prompt "Base.")))
      (should (string-match-p "Simplified Chinese" prompt))
      ;; And it says not to translate the things that have to stay
      ;; searchable, which is the failure mode of asking for a language.
      (should (string-match-p "file paths" prompt))))
  (let ((chat-reply-language nil))
    (should-not (string-match-p "Answer in"
                                (chat-tool-caller-build-system-prompt "Base.")))))

(ert-deftest chat-prompt-language-is-a-separate-switch ()
  "What the user reads is cosmetic.  What the model reads is not."
  (let ((chat-language 'zh-CN)
        (chat-prompt-language 'follow))
    (should (eq (chat-prompt-language-resolved) 'zh-CN)))
  (let ((chat-language 'zh-CN)
        (chat-prompt-language 'en))
    (should (eq (chat-prompt-language-resolved) 'en))
    ;; Pinned to English, a Chinese interface still sends English
    ;; instructions -- which is the point of having the switch.
    (should (equal (chat-i18n-prompt 'assistant-persona "You are helpful.")
                   "You are helpful."))))

(ert-deftest chat-prompt-language-falls-back-per-key ()
  "A catalog that translates half the prompts leaves the other half in
English rather than dropping back wholesale."
  (let ((chat-prompt-language 'zh-CN))
    (should (string-match-p "[一-龥]"
                            (chat-i18n-prompt 'assistant-persona "You are helpful.")))
    (should (equal (chat-i18n-prompt 'no-such-prompt-key "untranslated")
                   "untranslated"))))

(ert-deftest chat-prompt-language-leaves-the-contracts-alone ()
  "Tool names and JSON keys are matched literally by a parser.

A translated prompt that renamed them would break tool calling, which is
why only prose is in the prompt catalog."
  (let ((chat-language 'zh-CN)
        (chat-prompt-language 'zh-CN))
    (let ((prompt (chat-tool-caller-build-system-prompt "Base.")))
      (should (string-match-p "function_call" prompt))
      (should (string-match-p "apply_patch" prompt))
      (should (string-match-p "\\*\\*\\* Begin Patch" prompt)))))

(ert-deftest chat-prompt-a-customized-prompt-wins-over-its-translation ()
  "A value the user set is not a default to be localized away."
  (let ((chat-prompt-language 'zh-CN)
        (chat-code-system-prompt "Only do what I said."))
    (should (equal (chat-code--persona-prompt) "Only do what I said."))))

(ert-deftest chat-prompt-highest-priority-rules-follow-the-language ()
  "The interaction rules are pure prose, so they ship translated.
Unlike the technical rule lists, nothing in them is matched literally
by a parser."
  (let ((chat-prompt-language 'zh-CN))
    (let ((prompt (chat-code--compose-system-prompt)))
      (should (string-match-p "最高优先级任务规则：" prompt))
      (should (string-match-p "禁止情绪劳动" prompt))))
  (let ((chat-prompt-language 'en))
    (should (string-prefix-p "Highest-priority task rules:\n- Indulging"
                             (chat-code--compose-system-prompt)))))

(ert-deftest chat-prompt-customized-rules-win-over-their-translation ()
  "A rule list the user set is not a default to be localized away."
  (let ((chat-prompt-language 'zh-CN)
        (chat-code-highest-priority-rules '("My own rule.")))
    (should (string-prefix-p "Highest-priority task rules:\n- My own rule."
                             (chat-code--compose-system-prompt)))))

(ert-deftest chat-help-text-follows-the-language ()
  "The surface shows the catalog entry, not the English constant."
  (let ((chat-language 'zh-CN))
    (should (equal (chat-help-text) (chat-i18n-lookup 'help-text 'zh-CN))))
  (let ((chat-language 'en))
    (should (equal (chat-help-text) chat-commands-help))))

(provide 'test-chat-i18n)
;;; test-chat-i18n.el ends here
