;;; test-chat-wiki.el --- Tests for the wiki -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: tests

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Unit tests for the wiki.  The module shipped with none, which is how a
;; quote where a backquote was meant survived four months of writing the
;; literal text "(, (chat-wiki--now-string))" into every index it built.
;;
;; Weighted towards the things that were broken rather than towards
;; coverage: CJK titles and CJK search, the log that rewrote itself whole
;; on every append, the templates that failed the module's own lint the
;; moment they were created, and the boundary between the part of a
;; `/wiki' line that folds and the part that must not.

;;; Code:

(require 'ert)
(require 'test-helper)
(require 'chat-wiki)

(defmacro test-wiki--with-store (&rest body)
  "Run BODY with a temporary wiki root."
  `(chat-test-with-temp-dir
    (let ((chat-wiki-root (file-name-as-directory temp-dir)))
      ,@body)))

(defun test-wiki--page (type name body)
  "Create a page of TYPE called NAME whose content is BODY."
  (chat-wiki-create-page
   type name
   (format "---\ntitle: %s\ntype: %s\n---\n\n# %s\n\n%s\n"
           name (symbol-name type) name body)))

;; ------------------------------------------------------------------
;; Nothing happens on load
;; ------------------------------------------------------------------

(ert-deftest chat-wiki-does-not-create-itself-until-used ()
  "Naming a root does not bring it into being.

Loading this file used to run `chat-wiki-initialize' whenever a `wiki'
directory happened to sit next to wherever Emacs started, so requiring
chat.el created directories and wrote two files in a place the user never
named."
  (chat-test-with-temp-dir
   (let ((chat-wiki-root (expand-file-name "not-yet/" temp-dir)))
     (should-not (file-directory-p chat-wiki-root))
     ;; A read is not a write either.
     (should-not (chat-wiki-list-pages))
     (should-not (file-directory-p chat-wiki-root)))))

;; ------------------------------------------------------------------
;; Frontmatter
;; ------------------------------------------------------------------

(ert-deftest chat-wiki-frontmatter-parses-across-lines ()
  "Real frontmatter has one key per line.

The regexp this replaces used `.' to span the block, and `.' does not
match a newline, so nothing with two keys in it ever parsed."
  (let ((parsed (chat-wiki--parse-frontmatter
                 "---\ntitle: Context Budget\ntype: concept\n---\n\nBody.\n")))
    (should (equal (cdr (assq 'title (car parsed))) "Context Budget"))
    (should (equal (cdr (assq 'type (car parsed))) "concept"))))

(ert-deftest chat-wiki-frontmatter-is-not-left-in-the-body ()
  "The YAML belongs to the header, not to the prose.

While it parsed as absent, the raw keys stayed at the top of the body --
which is why a page of nothing but headings counted as written."
  (let ((parsed (chat-wiki--parse-frontmatter
                 "---\ntitle: T\ntype: concept\n---\n\nBody.\n")))
    (should-not (string-match-p "title:" (cdr parsed)))
    (should (string-match-p "Body\\." (cdr parsed)))))

(ert-deftest chat-wiki-text-without-frontmatter-is-all-body ()
  "A page that opens with prose has no header to take off it."
  (let ((parsed (chat-wiki--parse-frontmatter "# Title\n\nBody.\n")))
    (should-not (car parsed))
    (should (equal (cdr parsed) "# Title\n\nBody.\n"))))

(ert-deftest chat-wiki-an-unclosed-header-is-not-frontmatter ()
  "Three dashes and no closing line is a horizontal rule, not a header."
  (let ((parsed (chat-wiki--parse-frontmatter "---\ntitle: T\n\nBody.\n")))
    (should-not (car parsed))))

(ert-deftest chat-wiki-a-page-keeps-its-title-through-a-write-and-read ()
  "The title survives the round trip, rather than decaying to the slug."
  (test-wiki--with-store
   (chat-wiki-tool-write "concepts" "Context Budget" "Body.")
   (let ((page (car (chat-wiki-list-pages))))
     (should (equal (plist-get page :title) "Context Budget")))))

;; ------------------------------------------------------------------
;; Slugs
;; ------------------------------------------------------------------

(ert-deftest chat-wiki-a-cjk-title-keeps-its-characters ()
  "A Chinese title slugifies to something, not to nothing.

Stripping non-ASCII left the empty string, so the first CJK page took the
name and every later one collided with it."
  (should (equal (chat-wiki--slugify "多维表格") "多维表格")))

(ert-deftest chat-wiki-two-cjk-titles-do-not-collide ()
  "Different CJK titles get different slugs.

The bug this covers was not cosmetic: `chat-wiki-create-page' signals
when the file exists, so the second page could not be created at all."
  (should-not (equal (chat-wiki--slugify "多维表格")
                     (chat-wiki--slugify "电子表格"))))

(ert-deftest chat-wiki-a-mixed-title-keeps-both-scripts ()
  "Latin and CJK survive together, separated where the punctuation was."
  (should (equal (chat-wiki--slugify "多维表格 vs Base") "多维表格-vs-base")))

(ert-deftest chat-wiki-a-title-of-punctuation-still-gets-a-name ()
  "A title with no letters in it falls back to a digest, not to nothing."
  (let ((slug (chat-wiki--slugify "!!! ???")))
    (should-not (string-empty-p slug))
    (should (string-prefix-p "page-" slug))))

(ert-deftest chat-wiki-punctuation-titles-do-not-share-a-name ()
  "The fallback distinguishes, which is the whole point of having one."
  (should-not (equal (chat-wiki--slugify "!!!")
                     (chat-wiki--slugify "???"))))

(ert-deftest chat-wiki-a-slug-does-not-outgrow-a-filename ()
  "A long title is truncated, and not left ending in a hyphen."
  (let ((slug (chat-wiki--slugify (make-string 400 ?a))))
    (should (<= (length slug) chat-wiki--slug-max-length))
    (should-not (string-suffix-p "-" slug))))

;; ------------------------------------------------------------------
;; Tokenizing and search
;; ------------------------------------------------------------------

(ert-deftest chat-wiki-cjk-tokenizes-one-character-at-a-time ()
  "A Chinese phrase yields its characters, not itself.

Splitting on whitespace made a Chinese sentence exactly one token, which
was then matched as a substring -- so a real question found nothing."
  (should (equal (chat-wiki--tokenize "多维表格")
                 '("多" "维" "表" "格"))))

(ert-deftest chat-wiki-latin-tokenizes-by-word ()
  "Latin still splits on the boundaries between words."
  (should (equal (chat-wiki--tokenize "context budget") '("context" "budget"))))

(ert-deftest chat-wiki-a-mixed-run-splits-at-the-script-boundary ()
  "Latin next to CJK with no space between still separates.

The naive regexp for this swallows the CJK into the Latin token, because
the class that matches letters matches both."
  (should (equal (chat-wiki--tokenize "base多维") '("base" "多" "维"))))

(ert-deftest chat-wiki-search-finds-a-chinese-page-by-a-chinese-question ()
  "The regression: Chinese search used to return nothing at all."
  (test-wiki--with-store
   (test-wiki--page 'concepts "上下文预算" "预算把窗口分给各个类别。")
   (let ((hits (chat-wiki-index-search "上下文预算是怎么算的？")))
     (should hits)
     (should (equal (plist-get (car hits) :title) "上下文预算")))))

(ert-deftest chat-wiki-search-ranks-a-title-match-first ()
  "A page about the subject outranks one that mentions it in passing.

The old search was an OR that returned directory order, so the two were
indistinguishable in the result."
  (test-wiki--with-store
   (test-wiki--page 'concepts "Streaming" "How tokens arrive one at a time.")
   (test-wiki--page 'concepts "Budgets"
                    "Unrelated prose that happens to say streaming once.")
   (let ((hits (chat-wiki-index-search "streaming")))
     (should (= (length hits) 2))
     (should (equal (plist-get (car hits) :title) "Streaming")))))

(ert-deftest chat-wiki-search-of-nothing-matches-nothing ()
  "An empty query is not a match-everything query."
  (test-wiki--with-store
   (test-wiki--page 'concepts "Streaming" "Prose.")
   (should-not (chat-wiki-index-search "   "))))

;; ------------------------------------------------------------------
;; The log
;; ------------------------------------------------------------------

(ert-deftest chat-wiki-the-log-appends-rather-than-rewriting ()
  "Every entry is kept, newest last."
  (test-wiki--with-store
   (chat-wiki-log-append 'test "first")
   (chat-wiki-log-append 'test "second")
   (let ((text (with-temp-buffer
                 (insert-file-contents (chat-wiki--log-path))
                 (buffer-string))))
     (should (string-match-p "first" text))
     (should (string-match-p "second" text))
     (should (< (string-match "first" text) (string-match "second" text))))))

(ert-deftest chat-wiki-the-log-leaves-no-backup-beside-it ()
  "Appending does not litter.

`write-file' left a log.md~ next to the log on every single entry, which
is what put one in the repository."
  (test-wiki--with-store
   (chat-wiki-log-append 'test "one")
   (chat-wiki-log-append 'test "two")
   (should-not (file-exists-p (concat (chat-wiki--log-path) "~")))))

(ert-deftest chat-wiki-the-log-keeps-its-header-once ()
  "The header is written when the file is created and not again."
  (test-wiki--with-store
   (chat-wiki-log-append 'test "one")
   (chat-wiki-log-append 'test "two")
   (let ((text (with-temp-buffer
                 (insert-file-contents (chat-wiki--log-path))
                 (buffer-string))))
     (should (= 1 (cl-count "# Wiki Log"
                            (split-string text "\n")
                            :test #'equal))))))

(ert-deftest chat-wiki-recent-entries-come-from-the-end ()
  "The last N, since that is where the new ones are."
  (test-wiki--with-store
   (dolist (n '("a" "b" "c" "d"))
     (chat-wiki-log-append 'test n))
   (let ((recent (chat-wiki-log-recent 2)))
     (should (= (length recent) 2))
     (should (string-match-p "c" (nth 0 recent)))
     (should (string-match-p "d" (nth 1 recent))))))

;; ------------------------------------------------------------------
;; The index
;; ------------------------------------------------------------------

(ert-deftest chat-wiki-the-index-records-a-real-timestamp ()
  "Not the source text of the expression meant to produce one.

Under a plain quote the comma is data, so the literal
\"(, (chat-wiki--now-string))\" was written as the timestamp."
  (test-wiki--with-store
   (test-wiki--page 'concepts "Streaming" "Prose enough to be a page.")
   (let ((text (with-temp-buffer
                 (insert-file-contents (chat-wiki-index-update))
                 (buffer-string))))
     (should-not (string-match-p "chat-wiki--now-string" text))
     (should (string-match-p "updated: [0-9][0-9][0-9][0-9]-" text)))))

;; ------------------------------------------------------------------
;; Lint
;; ------------------------------------------------------------------

(ert-deftest chat-wiki-a-fresh-page-is-honestly-empty ()
  "A page created from a template has no content yet, and lint says so."
  (test-wiki--with-store
   (chat-wiki-create-page 'concepts "Streaming")
   (let ((issues (chat-wiki-lint)))
     (should (seq-find (lambda (i) (eq (plist-get i :type) 'empty)) issues)))))

(ert-deftest chat-wiki-a-page-with-prose-is-not-called-empty ()
  "Content is content, whatever words it happens to contain."
  (test-wiki--with-store
   (test-wiki--page 'concepts "Streaming"
                    "Tokens arrive one at a time and the display appends
each delta rather than redrawing the whole reply.")
   (should-not (seq-find (lambda (i) (eq (plist-get i :type) 'empty))
                         (chat-wiki-lint)))))

(ert-deftest chat-wiki-a-page-may-discuss-todo-without-being-a-stub ()
  "The word is not the condition.

Lint used to grep for TODO, FIXME, stub and placeholder, so a wiki about
software flagged its own subject matter."
  (test-wiki--with-store
   (test-wiki--page 'concepts "Code Review"
                    "A TODO left in a patch is a placeholder for work that
the author intends to do, and reviewers should ask about it.")
   (should-not (seq-find (lambda (i) (eq (plist-get i :type) 'empty))
                         (chat-wiki-lint)))))

(ert-deftest chat-wiki-a-template-page-has-no-dangling-links ()
  "A fresh page invents no links, so it cannot arrive with broken ones.

The templates used to ship [[entity1]] and [[concept1]], which were
dangling by construction: lint reported them on a wiki nobody had touched."
  (test-wiki--with-store
   (chat-wiki-create-page 'sources "Some Article")
   (should-not (seq-find (lambda (i) (eq (plist-get i :type) 'broken-link))
                         (chat-wiki-lint)))))

;; ------------------------------------------------------------------
;; The command surface
;; ------------------------------------------------------------------

(ert-deftest chat-wiki-every-subcommand-has-a-handler ()
  "The table is the surface, so nothing in it may be a dead name."
  (dolist (name (chat-wiki-subcommand-names))
    (let ((handler (cdr (assoc name chat-wiki--subcommands))))
      (should (fboundp handler)))))

(ert-deftest chat-wiki-every-alias-points-at-a-real-subcommand ()
  "An alias for a name that does not exist is worse than no alias."
  (dolist (pair chat-wiki--subcommand-aliases)
    (should (assoc (cdr pair) chat-wiki--subcommands))))

(ert-deftest chat-wiki-no-alias-shadows-a-subcommand ()
  "A canonical name may not be spelled as an alias of another."
  (dolist (pair chat-wiki--subcommand-aliases)
    (should-not (assoc (car pair) chat-wiki--subcommands))))

(defmacro test-wiki--reported (&rest body)
  "Run BODY and return what it reported."
  `(let ((said nil))
     (cl-letf (((symbol-function 'chat-wiki--report)
                (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
       ,@body)
     said))

(ert-deftest chat-wiki-a-bare-command-explains-itself ()
  "`/wiki' with nothing after it is a request for the usage."
  (should (string-match-p "ingest" (test-wiki--reported (chat-wiki-dispatch "")))))

(ert-deftest chat-wiki-an-unknown-subcommand-says-which-one ()
  "Naming it back is what tells a reader they mistyped."
  (let ((said (test-wiki--reported (chat-wiki-dispatch "ingset foo"))))
    (should (string-match-p "ingset" said))))

(ert-deftest chat-wiki-a-subcommand-folds-from-fullwidth ()
  "The verb belongs to this program, so it folds.

Decision 0014: normalization follows ownership."
  (let ((reached nil))
    (cl-letf (((symbol-function 'chat-wiki--sub-search)
               (lambda (arg) (setq reached arg))))
      (chat-wiki-dispatch "ｓｅａｒｃｈ budget"))
    (should (equal reached "budget"))))

(ert-deftest chat-wiki-a-subcommand-is-case-insensitive ()
  "Shift is not a different command."
  (let ((reached nil))
    (cl-letf (((symbol-function 'chat-wiki--sub-search)
               (lambda (arg) (setq reached arg))))
      (chat-wiki-dispatch "SEARCH budget"))
    (should (equal reached "budget"))))

(ert-deftest chat-wiki-a-localized-subcommand-reaches-the-handler ()
  "The Chinese name is the same command."
  (let ((reached nil))
    (cl-letf (((symbol-function 'chat-wiki--sub-search)
               (lambda (arg) (setq reached arg))))
      (chat-wiki-dispatch "搜索 预算"))
    (should (equal reached "预算"))))

(ert-deftest chat-wiki-an-argument-arrives-exactly-as-typed ()
  "The boundary: the verb folds and its argument does not.

A search string, a title and a path are data.  Folding the fullwidth
characters out of them would change what was asked for."
  (let ((reached nil))
    (cl-letf (((symbol-function 'chat-wiki--sub-search)
               (lambda (arg) (setq reached arg))))
      (chat-wiki-dispatch "search ｆｕｌｌｗｉｄｔｈ"))
    (should (equal reached "ｆｕｌｌｗｉｄｔｈ"))))

(ert-deftest chat-wiki-a-multi-word-argument-stays-whole ()
  "Only the first token is the subcommand."
  (let ((reached nil))
    (cl-letf (((symbol-function 'chat-wiki--sub-search)
               (lambda (arg) (setq reached arg))))
      (chat-wiki-dispatch "search context budget table"))
    (should (equal reached "context budget table"))))

;; ------------------------------------------------------------------
;; Tools
;; ------------------------------------------------------------------

(ert-deftest chat-wiki-a-written-page-can-be-read-back ()
  "The pair of tools the model uses has to agree with itself."
  (test-wiki--with-store
   (chat-wiki-tool-write "concepts" "Context Budget"
                         "The window is divided by category.")
   (should (string-match-p "divided by category"
                           (chat-wiki-tool-read "Context Budget")))))

(ert-deftest chat-wiki-appending-keeps-what-was-there ()
  "Append is not replace."
  (test-wiki--with-store
   (chat-wiki-tool-write "concepts" "Context Budget" "First finding.")
   (chat-wiki-tool-write "concepts" "Context Budget" "Second finding."
                         "append")
   (let ((body (chat-wiki-tool-read "Context Budget")))
     (should (string-match-p "First finding" body))
     (should (string-match-p "Second finding" body)))))

(ert-deftest chat-wiki-writing-without-a-mode-replaces ()
  "The default is replace, so the absence of a mode is not an append."
  (test-wiki--with-store
   (chat-wiki-tool-write "concepts" "Context Budget" "First finding.")
   (chat-wiki-tool-write "concepts" "Context Budget" "Only this.")
   (let ((body (chat-wiki-tool-read "Context Budget")))
     (should-not (string-match-p "First finding" body))
     (should (string-match-p "Only this" body)))))

(ert-deftest chat-wiki-a-cjk-page-round-trips-through-the-tools ()
  "The slug fix is what makes this work at all."
  (test-wiki--with-store
   (chat-wiki-tool-write "concepts" "上下文预算" "窗口按类别划分。")
   (should (string-match-p "窗口按类别划分"
                           (chat-wiki-tool-read "上下文预算")))))

(ert-deftest chat-wiki-reading-a-page-that-is-not-there-says-so ()
  "A tool result is read by a model, so it has to be a sentence."
  (test-wiki--with-store
   (should (string-match-p "No wiki page"
                           (chat-wiki-tool-read "Nothing Like This")))))

(ert-deftest chat-wiki-writing-refuses-an-unknown-type ()
  "A type outside the set would create a directory nothing lists."
  (test-wiki--with-store
   (let ((result (chat-wiki-tool-write "notes" "Whatever" "Body.")))
     (should (string-match-p "No such page type" result)))))

(ert-deftest chat-wiki-writing-refuses-a-nameless-page ()
  "There would be no way to read it back."
  (test-wiki--with-store
   (should (string-match-p "needs a name"
                           (chat-wiki-tool-write "concepts" "  " "Body.")))))

(ert-deftest chat-wiki-the-search-tool-returns-titles-not-bodies ()
  "What keeps a search cheap in context.

Returning the pages themselves would put an unbounded amount of text into
a reply the model did not choose the size of."
  (test-wiki--with-store
   (chat-wiki-tool-write "concepts" "Context Budget"
                         "A very distinctive sentence about allocation.")
   (let ((result (chat-wiki-tool-search "budget")))
     (should (string-match-p "Context Budget" result))
     (should-not (string-match-p "distinctive sentence" result)))))

(provide 'test-chat-wiki)
;;; test-chat-wiki.el ends here
