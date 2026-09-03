;;; chat-i18n.el --- Language for what the user reads -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: convenience, i18n

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Emacs has no gettext, and pulling one in for a handful of strings buys
;; a build step and a message catalog format nobody here can read.  This
;; is a plain alist of catalogs keyed by symbol, resolved once per lookup.
;;
;; Four separate things live here, because they fail differently:
;;
;; - Text the user reads.  `chat-i18n' looks up a key and falls back to
;;   the English written at the call site.  A missing key degrades to
;;   readable rather than to blank.
;;
;; - Command names.  `/auto' and `/自动' have to reach the same handler, so
;;   a language contributes aliases rather than its own command table.
;;   Aliases from every language are accepted at once -- a bilingual user
;;   types whichever comes to hand -- while completion offers only the
;;   names of the language in use.
;;
;; - Prompt text sent to the model.  Separate catalogs and a separate
;;   switch, because this one is not cosmetic: translated guidance changes
;;   what the model does, and the effect cannot be measured from here.
;;   English is the base version, and anything a language has no entry for
;;   stays English rather than going missing.  Machine-read contracts --
;;   JSON keys, tool names, patch envelopes, fence languages -- are never
;;   translated at all; they are matched literally by a parser.
;;
;; - The language the model should answer in.  This is the reliable lever:
;;   models follow "answer in Japanese" well regardless of what language
;;   the instruction arrived in.  It is stated to the model explicitly
;;   rather than left to be inferred from the user's phrasing.
;;
;; What this deliberately does not try to be is a pluralization engine.
;; When a count needs a plural, the catalog entry takes the whole phrase
;; rather than a stem plus a suffix, which is the part machine translation
;; gets wrong and the part that does not generalize past English anyway.

;;; Code:

(require 'seq)

(defgroup chat-i18n nil
  "Language of the text chat.el shows."
  :group 'chat
  :prefix "chat-i18n-")

(defconst chat-i18n-fallback-language 'en
  "The language every catalog is completed against.")

(defcustom chat-language 'auto
  "Language for text chat.el shows.

`auto' takes it from the Emacs language environment, which is what the
user already set for everything else.  A symbol names a catalog in
`chat-i18n-catalogs' directly."
  :type '(choice (const :tag "From the Emacs language environment" auto)
                 (const :tag "English" en)
                 (const :tag "Simplified Chinese" zh-CN)
                 (symbol :tag "Other catalog"))
  :group 'chat-i18n)

(defvar chat-i18n-catalogs
  '((en . nil)
    (zh-CN . nil))
  "Alist of language symbol to its catalog of key/string pairs.

English is present and empty on purpose: the English text lives at the
call sites, so a key with no entry anywhere still reads as English.  A
language listed here with no entries is a declared intention, not a
promise; `chat-i18n-coverage' says how far along it is.")

(defconst chat-i18n-language-names
  '((en . "English")
    (zh-CN . "Simplified Chinese"))
  "What to call each language when telling the model to use it.

In English, because this reaches the model as an instruction and the
English name of a language is the form a model is most likely to have
seen.  A language absent from here is named by its own symbol.")

(defconst chat-i18n--language-aliases
  '(("chinese-gbk" . zh-CN)
    ("chinese-gb18030" . zh-CN)
    ("chinese-big5" . zh-CN)
    ("chinese" . zh-CN)
    ("zh_cn" . zh-CN)
    ("zh-cn" . zh-CN)
    ("zh" . zh-CN)
    ("english" . en)
    ("en_us" . en)
    ("en" . en))
  "Maps what a locale or language environment calls itself to a catalog.

Matched as a prefix on a downcased name, so `zh_CN.UTF-8' and
`Chinese-GB18030' both arrive somewhere sensible.")

(defun chat-i18n--from-environment ()
  "Return the language symbol the environment implies, or nil.

The language environment is checked before the locale variables because
it is what the user set inside Emacs, and it is what they would look at
to explain the result."
  (let ((names (delq nil
                     (list (and (boundp 'current-language-environment)
                                current-language-environment)
                           (getenv "LC_ALL")
                           (getenv "LC_MESSAGES")
                           (getenv "LANG")))))
    (seq-some
     (lambda (name)
       (let ((lowered (downcase name)))
         (cdr (seq-find (lambda (alias)
                          (string-prefix-p (car alias) lowered))
                        chat-i18n--language-aliases))))
     names)))

(defun chat-i18n-language ()
  "Return the language catalog to read from.

An explicit `chat-language' goes through the same alias table as the
environment: the catalogs are keyed `zh-CN', and a user writing 'zh-cn
or \"zh_CN\" has no reason to learn that casing."
  (or (if (eq chat-language 'auto)
          (chat-i18n--from-environment)
        (cdr (seq-find
              (lambda (alias)
                (string-prefix-p (car alias)
                                 (downcase (format "%s" chat-language))))
              chat-i18n--language-aliases)))
      chat-i18n-fallback-language))

(defun chat-i18n-catalog (language)
  "Return the catalog for LANGUAGE, which may be empty."
  (cdr (assq language chat-i18n-catalogs)))

(defun chat-i18n-register (language entries)
  "Add ENTRIES to the catalog for LANGUAGE, replacing keys it already has.

ENTRIES is an alist of key symbol to string.  Called at load time by
whatever owns the strings, so a catalog is assembled from the modules
that use it rather than from one file that has to know about all of
them."
  (let ((existing (assq language chat-i18n-catalogs)))
    (unless existing
      (setq existing (cons language nil))
      (push existing chat-i18n-catalogs))
    (dolist (entry entries)
      (setf (alist-get (car entry) (cdr existing)) (cdr entry)))
    (cdr existing)))

(defun chat-i18n-lookup (key &optional language)
  "Return the string for KEY in LANGUAGE, or nil when it has none."
  (alist-get key (chat-i18n-catalog (or language (chat-i18n-language)))))

(defun chat-i18n (key default &rest arguments)
  "Return the localized text for KEY, formatted with ARGUMENTS.

DEFAULT is the English text, written at the call site so the source
stays readable and so a key nobody has translated still says something.
It is also what a reviewer compares a translation against."
  (let ((template (or (chat-i18n-lookup key) default)))
    (if arguments
        (apply #'format template arguments)
      template)))

;;; Command names

(defvar chat-i18n-aliases nil
  "Alist of language symbol to an alist of alias name to canonical name.

A language does not get its own command table.  It contributes names that
resolve to the canonical ASCII ones, so `/自动' and `/auto' are the same
command reached two ways and every property of that command -- whether it
can hold plain input, whether it runs while busy -- is declared once.")

(defun chat-i18n-register-aliases (language aliases)
  "Add ALIASES for LANGUAGE, an alist of alias name to canonical name.

Declaration order is kept, because two aliases may name one command and
the first one declared is the one offered for it.  Building this list
with `push' would silently make the last synonym the primary name."
  (let ((existing (assq language chat-i18n-aliases)))
    (unless existing
      (setq existing (cons language nil))
      (setq chat-i18n-aliases (append chat-i18n-aliases (list existing))))
    (dolist (alias aliases)
      (if-let ((present (assoc (car alias) (cdr existing))))
          (setcdr present (cdr alias))
        (setf (cdr existing)
              (append (cdr existing) (list (cons (car alias) (cdr alias)))))))
    (cdr existing)))

(defun chat-i18n-language-aliases (&optional language)
  "Return the alias alist for LANGUAGE, defaulting to the one in use."
  (cdr (assq (or language (chat-i18n-language)) chat-i18n-aliases)))

(defun chat-i18n-resolve-alias (name)
  "Return the canonical command name NAME stands for, or nil.

Every language is searched, not only the one in use: a name that means
something in some language means it whatever the interface is set to, and
refusing a name the user knows in order to be consistent about locale
would be pedantry with no upside."
  (seq-some (lambda (catalog)
              (cdr (assoc name (cdr catalog))))
            chat-i18n-aliases))

(defun chat-i18n-localized-name (canonical &optional language)
  "Return the LANGUAGE alias for CANONICAL, or nil when it has none.

Nil for the fallback language, whose aliases are alternative spellings
rather than translations: the canonical name is already the English one,
and offering `ask' in place of `send' would hide the name everything else
is written in."
  (let ((language (or language (chat-i18n-language))))
    (unless (eq language chat-i18n-fallback-language)
      (car (rassoc canonical (chat-i18n-language-aliases language))))))

;;; Prompt text and the language of the reply

(defcustom chat-prompt-language 'follow
  "Language for the instructions sent to the model.

Separate from `chat-language' because it is not cosmetic.  Translated
guidance changes what the model does, and whether it does it better
cannot be measured from inside Emacs: the same model can follow the same
instruction differently in two languages.  Pin this to `en' if a
translated prompt starts behaving worse than the English one.

`follow' takes the language from `chat-language'.  Machine-read parts of
a prompt -- JSON keys, tool names, patch envelopes -- are never
translated regardless of this setting."
  :type '(choice (const :tag "Follow the interface language" follow)
                 (const :tag "English" en)
                 (const :tag "Simplified Chinese" zh-CN)
                 (symbol :tag "Other catalog"))
  :group 'chat-i18n)

(defcustom chat-reply-language 'follow
  "Language the model is told to answer in.

`follow' takes it from `chat-language'.  A string is passed through as
the name of a language, so a language with no catalog here can still be
asked for.  nil says nothing to the model, which leaves it to infer the
language from what the user wrote."
  :type '(choice (const :tag "Follow the interface language" follow)
                 (const :tag "Let the model infer it" nil)
                 (const :tag "English" en)
                 (const :tag "Simplified Chinese" zh-CN)
                 (string :tag "Named language")
                 (symbol :tag "Other catalog"))
  :group 'chat-i18n)

(defvar chat-i18n-prompt-catalogs
  '((en . nil))
  "Alist of language symbol to its catalog of prompt key/string pairs.

Kept apart from `chat-i18n-catalogs' so the two switches are independent
and so prompt coverage does not flatter or depress the interface figure.")

(defun chat-i18n-register-prompts (language entries)
  "Add ENTRIES to the prompt catalog for LANGUAGE."
  (let ((existing (assq language chat-i18n-prompt-catalogs)))
    (unless existing
      (setq existing (cons language nil))
      (push existing chat-i18n-prompt-catalogs))
    (dolist (entry entries)
      (setf (alist-get (car entry) (cdr existing)) (cdr entry)))
    (cdr existing)))

(defun chat-prompt-language-resolved ()
  "Return the language prompt text is written in."
  (if (eq chat-prompt-language 'follow)
      (chat-i18n-language)
    (or chat-prompt-language chat-i18n-fallback-language)))

(defun chat-i18n-prompt (key default)
  "Return the prompt text for KEY, or DEFAULT when no language has it.

Falls back per key rather than per language: a catalog that translates
half the prompts leaves the other half in English instead of dropping
back wholesale, so a partial translation is worth having."
  (or (alist-get key (cdr (assq (chat-prompt-language-resolved)
                                chat-i18n-prompt-catalogs)))
      default))

(defun chat-reply-language-name ()
  "Return the name of the language the model should answer in, or nil."
  (let ((setting (if (eq chat-reply-language 'follow)
                     (chat-i18n-language)
                   chat-reply-language)))
    (cond
     ((null setting) nil)
     ((stringp setting) setting)
     (t (or (alist-get setting chat-i18n-language-names)
            (symbol-name setting))))))

(defun chat-i18n-keys ()
  "Return every key any catalog defines."
  (delete-dups
   (apply #'append
          (mapcar (lambda (catalog) (mapcar #'car (cdr catalog)))
                  chat-i18n-catalogs))))

(defun chat-i18n-missing-keys (language)
  "Return the keys LANGUAGE has no entry for."
  (let ((catalog (chat-i18n-catalog language)))
    (seq-remove (lambda (key) (assq key catalog)) (chat-i18n-keys))))

(defun chat-i18n-coverage (language)
  "Return how many of the known keys LANGUAGE covers, as a ratio 0..1.

The fallback language is complete by definition: its text lives at the
call sites, so an empty English catalog means every key already reads as
English rather than meaning nothing is translated."
  (if (eq language chat-i18n-fallback-language)
      1.0
    (let ((total (length (chat-i18n-keys))))
      (if (zerop total)
          1.0
        (/ (float (- total (length (chat-i18n-missing-keys language))))
           total)))))

(defun chat-i18n-report ()
  "Report catalog coverage, so the gap is a number rather than a feeling."
  (interactive)
  (message
   "Language %s. %d keys. %s"
   (chat-i18n-language)
   (length (chat-i18n-keys))
   (mapconcat
    (lambda (catalog)
      (let ((language (car catalog)))
        (if (eq language chat-i18n-fallback-language)
            (format "%s source" language)
          (format "%s %d%%" language
                  (round (* 100 (chat-i18n-coverage language)))))))
    chat-i18n-catalogs " ")))

(provide 'chat-i18n)
;;; chat-i18n.el ends here
