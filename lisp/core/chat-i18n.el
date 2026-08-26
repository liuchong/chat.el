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
;; What it deliberately does not try to be:
;;
;; - Complete.  Localizing every string in the package would be a very
;;   large diff for very little: most of them are log lines, error text
;;   from tools, and prompts sent to a model that is answering in the
;;   user's language anyway.  What is translated is what a person reads to
;;   learn the surface -- the help, and the feedback from the commands
;;   they type.  `chat-i18n-coverage' reports how much of a catalog is
;;   filled in, so the gap is a number rather than a feeling.
;;
;; - A pluralization engine.  When a count needs a plural, the catalog
;;   entry takes the whole phrase rather than a stem plus a suffix, which
;;   is the part machine translation gets wrong and the part that does not
;;   generalize past English anyway.
;;
;; A missing key falls back to English and then to the key itself, so a
;; half-finished translation degrades to readable rather than to blank.

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
  "Return the language catalog to read from."
  (or (if (eq chat-language 'auto)
          (chat-i18n--from-environment)
        chat-language)
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
