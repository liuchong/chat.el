;;; chat-wiki.el --- LLM Wiki pattern implementation for chat.el -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;; Author: chat.el contributors
;; Keywords: chat, wiki, knowledge, llm

;; This file is not part of GNU Emacs.

;;; Commentary:

;; A knowledge base kept as markdown on disk: typed pages that link to
;; each other with [[wikilinks]], with an index and a log generated from
;; them.  Being ordinary files is the point -- the store stays greppable,
;; versionable and editable by hand instead of living inside this program.
;;
;; The wiki is stored in a directory structure:
;;   wiki/
;;   ├── index.md            # Content index
;;   ├── log.md              # Chronological log
;;   ├── entities/           # Concrete entities
;;   ├── concepts/           # Abstract concepts
;;   ├── sources/            # Source document summaries
;;   ├── comparisons/        # Comparison analyses
;;   └── synthesis/          # Synthesis pages
;;
;; Two things separate this from `chat-knowledge.el', which also keeps
;; notes across sessions.  That store is flat, written by a run about what
;; it worked out, and its index rides in every prompt.  This one is
;; structured and linked, is meant to be read by a person as much as by a
;; model, and deliberately does not ride in the prompt: a wiki grows
;; without bound, and an index of it sitting in the fixed region of the
;; context would slowly starve the work it is supposed to help.  The model
;; reaches it through tools and pays for only the pages it asks for.
;;
;; The surface is one command with subcommands -- `/wiki ingest', `/wiki
;; ask' -- rather than a family of `/wiki-ingest' names.  Five top-level
;; names for one feature crowd the completion list of every other command,
;; and the shared prefix is doing the work of a namespace without being
;; one.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'chat-command)
(require 'chat-i18n)

;; The chat surface lives a layer up and requires this file, so the few
;; functions needed to answer in the buffer are declared rather than
;; required, and every call is guarded by `fboundp'.  Same arrangement as
;; `chat-knowledge.el' uses for the tool forge.
(declare-function chat-ui--insert-system-message "chat-ui" (content))
(declare-function chat-ui--send-user-message "chat-ui" (content))
(declare-function chat-tool-forge-register "chat-tool-forge" (tool))
(declare-function make-chat-forged-tool "chat-tool-forge" (&rest slots))

;; ------------------------------------------------------------------
;; Customization
;; ------------------------------------------------------------------

(defgroup chat-wiki nil
  "LLM Wiki pattern for chat.el."
  :group 'chat
  :prefix "chat-wiki-")

(defcustom chat-wiki-root (expand-file-name "~/.chat/wiki/")
  "Root directory for the wiki.

Under the user's chat state, beside the session and knowledge stores.  It
used to be \"wiki\" under `default-directory', resolved while this file
loaded, which made the location depend on where Emacs happened to be
started and let a `wiki' folder in an unrelated project become the target."
  :type 'directory
  :group 'chat-wiki)

(defcustom chat-wiki-index-file
  "index.md"
  "Name of the index file."
  :type 'string
  :group 'chat-wiki)

(defcustom chat-wiki-log-file
  "log.md"
  "Name of the log file."
  :type 'string
  :group 'chat-wiki)

(defcustom chat-wiki-default-format 'markdown
  "Default format for wiki pages (`markdown' or `org')."
  :type '(choice (const markdown)
                 (const org))
  :group 'chat-wiki)

(defcustom chat-wiki-enable-org-mode nil
  "Whether to enable Org-mode support alongside Markdown."
  :type 'boolean
  :group 'chat-wiki)

(defcustom chat-wiki-obsidian-support t
  "Whether to generate Obsidian-compatible links and metadata."
  :type 'boolean
  :group 'chat-wiki)

;; ------------------------------------------------------------------
;; Variables
;; ------------------------------------------------------------------

(defvar chat-wiki--page-types
  '((entities . "entities")
    (concepts . "concepts")
    (sources . "sources")
    (comparisons . "comparisons")
    (synthesis . "synthesis"))
  "Alist mapping page type symbols to directory names.")

(defvar chat-wiki--current-ingest nil
  "Current ingest operation data (for batch operations).")

;; ------------------------------------------------------------------
;; Utility Functions
;; ------------------------------------------------------------------

(defun chat-wiki--ensure-directory (dir)
  "Ensure DIR exists, creating it if necessary."
  (unless (file-directory-p dir)
    (make-directory dir t)))

(defconst chat-wiki--slug-max-length 80
  "Longest slug this generates, in characters.

Filenames have limits and titles do not.  Truncating here rather than
letting the filesystem refuse the write keeps the failure in one place.")

(defun chat-wiki--slugify (title)
  "Convert TITLE to a slug usable as a filename.

Letters and digits survive whatever script they are written in; anything
else collapses to a single hyphen.  Stripping non-ASCII, which is what
this did, slugified every CJK title to the empty string: the first such
page took the name, and creating a second one failed outright because the
name was already there.  A title made only of punctuation still needs a
name of its own, so it falls back to a digest rather than to nothing."
  (let* ((slug (replace-regexp-in-string "[^[:alnum:]]+" "-" (downcase title)))
         (slug (replace-regexp-in-string "\\`-+\\|-+\\'" "" slug))
         (slug (if (> (length slug) chat-wiki--slug-max-length)
                   (replace-regexp-in-string
                    "-+\\'" "" (substring slug 0 chat-wiki--slug-max-length))
                 slug)))
    (if (string-empty-p slug)
        (format "page-%s" (substring (secure-hash 'sha1 title) 0 8))
      slug)))

(defun chat-wiki--cjk-char-p (ch)
  "Return non-nil when CH carries meaning on its own.

Han, kana and hangul, which are written without spaces between words."
  (or (<= #x3400 ch #x4DBF)             ; CJK extension A
      (<= #x4E00 ch #x9FFF)             ; CJK unified ideographs
      (<= #xF900 ch #xFAFF)             ; compatibility ideographs
      (<= #x3040 ch #x30FF)             ; hiragana and katakana
      (<= #xAC00 ch #xD7AF)))           ; hangul syllables

(defun chat-wiki--tokenize (text)
  "Split TEXT into search tokens.

Runs of letters and digits tokenize as words, except that CJK tokenizes
one character at a time.  Splitting on whitespace, which is what the
search did, turns a Chinese question into a single token that is the whole
sentence -- then matched as a substring, which is why searching in Chinese
found nothing at all."
  (let ((tokens nil))
    (dolist (chunk (split-string (downcase text) "[^[:alnum:]]+" t))
      (let ((run nil))
        (dotimes (i (length chunk))
          (let ((ch (aref chunk i)))
            (if (chat-wiki--cjk-char-p ch)
                (progn
                  (when run
                    (push (apply #'string (nreverse run)) tokens)
                    (setq run nil))
                  (push (char-to-string ch) tokens))
              (push ch run))))
        (when run
          (push (apply #'string (nreverse run)) tokens))))
    (delete-dups (nreverse tokens))))

(defun chat-wiki--today-string ()
  "Return today's date as YYYY-MM-DD string."
  (format-time-string "%Y-%m-%d"))

(defun chat-wiki--now-string ()
  "Return current timestamp as YYYY-MM-DD HH:MM string."
  (format-time-string "%Y-%m-%d %H:%M"))

(defun chat-wiki--file-path (type filename)
  "Return full path for page of TYPE with FILENAME."
  (expand-file-name
   filename
   (expand-file-name
    (cdr (assoc type chat-wiki--page-types))
    chat-wiki-root)))

(defun chat-wiki--index-path ()
  "Return path to index file."
  (expand-file-name chat-wiki-index-file chat-wiki-root))

(defun chat-wiki--log-path ()
  "Return path to log file."
  (expand-file-name chat-wiki-log-file chat-wiki-root))

;; ------------------------------------------------------------------
;; Frontmatter Handling
;; ------------------------------------------------------------------

(defun chat-wiki--parse-frontmatter (content)
  "Parse YAML frontmatter from CONTENT.

Returns a cons cell (FRONTMATTER-ALIST . BODY).  Frontmatter is recognized
only when the text opens with a `---' line that a later `---' line closes.

Scanned over lines rather than matched with one regexp, because `.' does
not match a newline in an Emacs regexp: the pattern this replaces could
only ever match frontmatter that fitted on a single line, so every real
page parsed as having none at all.  That is what lost every title and
date -- both fell back to the filename -- and left the raw YAML sitting
at the top of the body, where it counted as content and made an empty
page look like a written one."
  (with-temp-buffer
    (insert content)
    (goto-char (point-min))
    (if (not (looking-at "---[ \t]*$"))
        (cons nil content)
      (forward-line 1)
      (let ((yaml-start (point)))
        (if (not (re-search-forward "^---[ \t]*$" nil t))
            (cons nil content)
          (let ((yaml-text (buffer-substring yaml-start (match-beginning 0)))
                (body (buffer-substring (min (point-max) (1+ (match-end 0)))
                                        (point-max)))
                (frontmatter nil))
            (dolist (line (split-string yaml-text "\n" t))
              (when (string-match "\\`\\([^:]+\\):[ \t]*\\(.+\\)\\'" line)
                (let ((key (intern (downcase (string-trim
                                              (match-string 1 line)))))
                      (value (string-trim (match-string 2 line))))
                  (when (string-match "\\`\"\\(.*\\)\"\\'" value)
                    (setq value (match-string 1 value)))
                  (when (string-match "\\`'\\(.*\\)'\\'" value)
                    (setq value (match-string 1 value)))
                  (push (cons key value) frontmatter))))
            (cons (nreverse frontmatter) body)))))))

(defun chat-wiki--write-frontmatter (alist)
  "Write YAML frontmatter from ALIST."
  (if (null alist)
      ""
    (concat "---\n"
            (mapconcat (lambda (pair)
                         (format "%s: %s"
                                 (car pair)
                                 (if (stringp (cdr pair))
                                     (if (string-match-p "[\"':#\n]" (cdr pair))
                                         (format "\"%s\"" (replace-regexp-in-string "\"" "\\\\\"" (cdr pair)))
                                       (cdr pair))
                                   (cdr pair))))
                       alist
                       "\n")
            "\n---\n\n")))

;; ------------------------------------------------------------------
;; WikiLink Handling
;; ------------------------------------------------------------------

(defun chat-wiki--wikilink-regexp ()
  "Return regexp pattern for WikiLinks [[Like This]].

The class is `[^]]', not `[^\\]]'.  A backslash is not an escape inside a
character alternative in an Emacs regexp, so the second form reads as
\"any character except backslash\" followed by a literal `]' -- which
matched no wikilink that has ever been written.  Link extraction
therefore always returned nothing, and with it every backlink, every
orphan report and every broken-link report."
  "\\[\\[\\([^]]+\\)\\]\\]")

(defun chat-wiki--extract-wikilinks (content)
  "Extract all WikiLinks from CONTENT.
Returns list of link targets."
  (let ((links nil)
        (regexp (chat-wiki--wikilink-regexp)))
    (with-temp-buffer
      (insert content)
      (goto-char (point-min))
      (while (re-search-forward regexp nil t)
        (push (match-string 1) links)))
    (delete-dups (nreverse links))))

(defun chat-wiki--find-backlinks (target &optional type)
  "Return the paths of pages linking to TARGET.
If TYPE is given, only pages of that type.

Compared as slugs, so `[[Context Budget]]' and `[[context-budget]]' both
count and an anchor does not stop the match.  This searched for the
literal text `[[TARGET]]' before, which meant the lint that used it
disagreed with the page lookup that resolves the same link -- one matched
the title as written and the other the slug."
  (let ((wanted (chat-wiki--slugify target))
        (backlinks nil))
    (dolist (page (chat-wiki--scan))
      (when (or (null type) (eq (plist-get page :type) type))
        (when (seq-find (lambda (link)
                          (equal (chat-wiki--link-target link) wanted))
                        (plist-get page :links))
          (push (plist-get page :path) backlinks))))
    (nreverse backlinks)))

;; ------------------------------------------------------------------
;; Page Management
;; ------------------------------------------------------------------

(defun chat-wiki--ensure-frontmatter (content type name)
  "Return CONTENT carrying frontmatter, adding it when it has none.

Every page is written through `chat-wiki-create-page', so putting the rule
here is what stops a page reaching disk without a title and a type.
Caller-supplied content used to be written verbatim, with frontmatter only
on pages generated from a template -- so every page created with a body,
which is every page the model writes and every ingest, had none.
`chat-wiki-read-page' then had nothing to read a title from, the index
listed slugs where titles belong, and search matched no title at all."
  (if (string-prefix-p "---" (string-trim-left content))
      content
    (concat (chat-wiki--write-frontmatter
             `((title . ,name)
               (type . ,(symbol-name type))
               (created . ,(chat-wiki--today-string))))
            (if (string-prefix-p "#" (string-trim-left content))
                ""
              (format "# %s\n\n" name))
            content
            (if (string-suffix-p "\n" content) "" "\n"))))

(defun chat-wiki-create-page (type name &optional content)
  "Create a new wiki page of TYPE with NAME and optional CONTENT.
Returns the file path of the created page."
  (chat-wiki--ensure-directory chat-wiki-root)
  (let* ((dir (expand-file-name
               (cdr (assoc type chat-wiki--page-types))
               chat-wiki-root))
         (filename (if (eq type 'sources)
                       (format "%s-%s.md"
                               (chat-wiki--today-string)
                               (chat-wiki--slugify name))
                     (format "%s.md" (chat-wiki--slugify name))))
         (filepath (expand-file-name filename dir)))
    (chat-wiki--ensure-directory dir)
    (when (file-exists-p filepath)
      (error "Page already exists: %s" filepath))
    (with-temp-file filepath
      (insert (if content
                  (chat-wiki--ensure-frontmatter content type name)
                (pcase type
                  ('sources (chat-wiki--source-template
                             name (chat-wiki--today-string) ""))
                  ('entities (chat-wiki--entity-template name "general"))
                  ('concepts (chat-wiki--concept-template name))
                  (_ (format "# %s\n\n" name))))))
    (chat-wiki-log-append 'create (format "%s/%s" (cdr (assoc type chat-wiki--page-types)) filename))
    filepath))

(defun chat-wiki-read-page (filepath)
  "Read wiki page at FILEPATH.
Returns a plist with :frontmatter, :body, :title, and :path."
  (unless (file-exists-p filepath)
    (error "Page not found: %s" filepath))
  (let* ((content (with-temp-buffer
                    (insert-file-contents filepath)
                    (buffer-string)))
         (parsed (chat-wiki--parse-frontmatter content))
         (frontmatter (car parsed))
         (body (cdr parsed))
         ;; `and', not `progn': a failed `string-match' leaves the match
         ;; data from whatever matched last, so calling `match-string'
         ;; regardless returned a slice of BODY at offsets belonging to an
         ;; unrelated string.  That is how a page with no frontmatter got a
         ;; title like a fragment of its own prose instead of the filename.
         (title (or (cdr (assoc 'title frontmatter))
                    (and (string-match "^# \\(.+\\)$" body)
                         (match-string 1 body))
                    (file-name-base filepath))))
    `(:frontmatter ,frontmatter
                   :body ,body
                   :title ,title
                   :path ,filepath)))

(defun chat-wiki-update-page (filepath new-content &optional frontmatter)
  "Update existing page at FILEPATH with NEW-CONTENT and optional FRONTMATTER.
Preserves existing frontmatter keys not in FRONTMATTER."
  (unless (file-exists-p filepath)
    (error "Page not found: %s" filepath))
  (let* ((existing (chat-wiki-read-page filepath))
         (existing-fm (plist-get existing :frontmatter))
         (merged-fm (append frontmatter
                            (cl-remove-if (lambda (pair)
                                            (assoc (car pair) frontmatter))
                                          existing-fm))))
    (with-temp-file filepath
      (insert (chat-wiki--write-frontmatter merged-fm))
      (insert new-content))
    (chat-wiki-log-append 'update (file-relative-name filepath chat-wiki-root))
    filepath))

(defun chat-wiki-list-pages (&optional type)
  "List all wiki pages.
If TYPE is specified, only list pages of that type.
Returns list of plists with :title, :path, :type, and :date."
  (let ((types (if type
                   (list (cons type (cdr (assoc type chat-wiki--page-types))))
                 chat-wiki--page-types))
        (pages nil))
    (dolist (type-pair types)
      (let ((dir (expand-file-name (cdr type-pair) chat-wiki-root)))
        (when (file-directory-p dir)
          (dolist (file (directory-files dir t "\\.md$"))
            (when (file-readable-p file)
              (condition-case nil
                  (let* ((page (chat-wiki-read-page file))
                         (fm (plist-get page :frontmatter)))
                    (push `(:title ,(plist-get page :title)
                                   :path ,file
                                   :type ,(car type-pair)
                                   :date ,(or (cdr (assoc 'date fm))
                                              (format-time-string
                                               "%Y-%m-%d"
                                               (file-attribute-modification-time
                                                (file-attributes file)))))
                          pages))
                (error nil)))))))
    (sort pages (lambda (a b)
                  (string> (or (plist-get a :date) "")
                           (or (plist-get b :date) ""))))))


;; ------------------------------------------------------------------
;; Page Templates
;; ------------------------------------------------------------------

(defun chat-wiki--source-template (title date source-url)
  "Generate source page template."
  (concat (chat-wiki--write-frontmatter
           `((title . ,title)
             (date . ,date)
             (type . "source")
             (source . ,source-url)
             (projects . "all")))
          (format "# %s\n\n" title)
          "## Metadata\n"
          (format "- **Date**: %s\n" date)
          (format "- **Source**: %s\n" (or source-url "unknown"))
          "- **Type**: article\n"
          "- **Projects**: all\n\n"
          ;; Empty sections rather than "Key takeaway 1" and [[entity1]].
          ;; The invented links were dangling by construction, so a fresh
          ;; page failed the module's own lint the moment it was created.
          "## Summary\n\n"
          "## Extracted Entities\n\n"
          "## Related Concepts\n\n"
          "## Integration Notes\n\n"))

(defun chat-wiki--entity-template (name type)
  "Generate entity page template."
  (concat (chat-wiki--write-frontmatter
           `((title . ,name)
             (type . ,type)
             (created . ,(chat-wiki--today-string))))
          (format "# %s\n\n" name)
          "## Basic Info\n"
          (format "- **Type**: %s\n" type)
          (format "- **Created**: %s\n\n" (chat-wiki--today-string))
          "## Description\n\n"
          "## Related\n\n"
          "## Sources\n\n"))

(defun chat-wiki--concept-template (name)
  "Generate concept page template."
  (concat (chat-wiki--write-frontmatter
           `((title . ,name)
             (type . "concept")
             (created . ,(chat-wiki--today-string))))
          (format "# %s\n\n" name)
          "## Definition\n\n"
          "## Notes\n\n"
          "## Comparisons\n\n"
          "## Sources\n\n"))

;; ------------------------------------------------------------------
;; Index Management
;; ------------------------------------------------------------------

(defun chat-wiki-index-update ()
  "Update index.md with current wiki state.
Returns the path to the index file."
  (chat-wiki--ensure-directory chat-wiki-root)
  (let ((index-path (chat-wiki--index-path))
        (pages (chat-wiki-list-pages))
        (sources nil)
        (entities nil)
        (concepts nil)
        (comparisons nil)
        (synthesis nil))
    ;; Categorize pages
    (dolist (page pages)
      (pcase (plist-get page :type)
        ('sources (push page sources))
        ('entities (push page entities))
        ('concepts (push page concepts))
        ('comparisons (push page comparisons))
        ('synthesis (push page synthesis))))
    ;; Generate index
    (with-temp-file index-path
      ;; Backquote, not quote: under a plain quote the comma is not an
      ;; unquote but two characters of data, and the literal text
      ;; "(, (chat-wiki--now-string))" went into the file as the timestamp.
      (insert (chat-wiki--write-frontmatter
               `((title . "Wiki Index")
                 (type . "index")
                 (updated . ,(chat-wiki--now-string)))))
      (insert "# Wiki Index\n\n")
      (insert (format "*Last updated: %s*\n\n" (chat-wiki--now-string)))
      ;; Statistics
      (insert "## Statistics\n\n")
      (insert (format "- **Sources**: %d\n" (length sources)))
      (insert (format "- **Entities**: %d\n" (length entities)))
      (insert (format "- **Concepts**: %d\n" (length concepts)))
      (insert (format "- **Comparisons**: %d\n" (length comparisons)))
      (insert (format "- **Synthesis**: %d\n\n" (length synthesis)))
      ;; Recent sources
      (insert "## Recent Sources\n\n")
      (dolist (source (seq-take sources 10))
        (insert (format "- [[%s]] (%s)\n"
                        (plist-get source :title)
                        (plist-get source :date))))
      (insert "\n")
      ;; Entities by type
      (when entities
        (insert "## Entities\n\n")
        (dolist (entity (sort entities (lambda (a b)
                                         (string< (plist-get a :title)
                                                  (plist-get b :title)))))
          (insert (format "- [[%s]]\n" (plist-get entity :title))))
        (insert "\n"))
      ;; Concepts
      (when concepts
        (insert "## Concepts\n\n")
        (dolist (concept (sort concepts (lambda (a b)
                                          (string< (plist-get a :title)
                                                   (plist-get b :title)))))
          (insert (format "- [[%s]]\n" (plist-get concept :title))))
        (insert "\n"))
      ;; All pages by date
      (insert "## All Pages by Date\n\n")
      (dolist (page (seq-take pages 20))
        (insert (format "- [%s] %s (%s)\n"
                        (plist-get page :date)
                        (plist-get page :title)
                        (symbol-name (plist-get page :type))))))
    (chat-wiki-log-append 'index "Updated index")
    index-path))

(defun chat-wiki-index-search (query)
  "Return pages matching QUERY, best match first.

Scored rather than filtered: a page earns a point for each distinct token
it contains and three for a token in its title, so a page about the
subject outranks one that mentions a word of it in passing.  The previous
version was an OR over the query's words and returned them in directory
order, which put an incidental match level with a real one."
  (let ((tokens (chat-wiki--tokenize query))
        (scored nil))
    (when tokens
      (dolist (page (chat-wiki-list-pages))
        (let* ((title (downcase (or (plist-get page :title) "")))
               (body (downcase
                      (or (ignore-errors
                            (plist-get (chat-wiki-read-page
                                        (plist-get page :path))
                                       :body))
                          "")))
               (score 0))
          (dolist (token tokens)
            (when (string-match-p (regexp-quote token) title)
              (setq score (+ score 3)))
            (when (string-match-p (regexp-quote token) body)
              (setq score (1+ score))))
          (when (> score 0)
            (push (cons score page) scored))))
      (mapcar #'cdr
              (sort (nreverse scored)
                    (lambda (a b) (> (car a) (car b))))))))

;; ------------------------------------------------------------------
;; Log Management
;; ------------------------------------------------------------------

(defun chat-wiki-log-append (operation description)
  "Append an entry for OPERATION with DESCRIPTION to log.md.

Only the new entry is written, at the end.  Reading the whole log in to
insert one line at the front and writing all of it back made each entry
cost more than the last, and `write-file' left a backup file beside the
log every single time.  Newest is therefore last, which is what
`chat-wiki-log-recent' now reads from."
  (chat-wiki--ensure-directory chat-wiki-root)
  (let ((log-path (chat-wiki--log-path))
        (entry (format "## [%s] %s | %s\n\n"
                       (chat-wiki--now-string)
                       (symbol-name operation)
                       description)))
    (unless (file-exists-p log-path)
      (with-temp-file log-path
        (insert (chat-wiki--write-frontmatter
                 '((title . "Wiki Log")
                   (type . "log"))))
        (insert "# Wiki Log\n\n")
        (insert "Chronological record of wiki operations.\n\n")))
    (write-region entry nil log-path t 'silent)
    log-path))

(defun chat-wiki-log-recent (&optional n)
  "Return the last N log entries, oldest first (default 20).

Taken from the end, because entries are appended there."
  (let ((log-path (chat-wiki--log-path))
        (n (or n 20)))
    (when (file-exists-p log-path)
      (with-temp-buffer
        (insert-file-contents log-path)
        (let ((entries nil))
          (goto-char (point-min))
          (while (re-search-forward "^## \\[[0-9]" nil t)
            (let* ((start (match-beginning 0))
                   (end (or (save-excursion
                              (when (re-search-forward "^## \\[[0-9]" nil t)
                                (match-beginning 0)))
                            (point-max))))
              (push (string-trim (buffer-substring start end)) entries)
              (goto-char end)))
          (setq entries (nreverse entries))
          (if (> (length entries) n)
              (last entries n)
            entries))))))

;; ------------------------------------------------------------------
;; Core Functions
;; ------------------------------------------------------------------

(defun chat-wiki-ingest (source-path title)
  "Ingest SOURCE-PATH as a wiki source with TITLE.
Returns the path to the created source page."
  (interactive
   (list (read-file-name "Source file: ")
         (read-string "Title: ")))
  (unless (file-exists-p source-path)
    (error "Source file not found: %s" source-path))
  ;; Read source content
  (let* ((source-content (with-temp-buffer
                           (insert-file-contents source-path)
                           (buffer-string)))
         (source-filename (file-name-nondirectory source-path))
         (date (chat-wiki--today-string)))
    ;; Create source page
    (let* ((page-path (chat-wiki-create-page
                       'sources
                       title
                       (chat-wiki--source-template title date source-path))))
      ;; Append full content as a quote block
      (with-temp-buffer
        (insert-file-contents page-path)
        (goto-char (point-max))
        (insert "\n## Full Content\n\n")
        (insert "```\n")
        (insert source-content)
        (insert "\n```\n")
        (write-file page-path))
      ;; Update index
      (chat-wiki-index-update)
      ;; Log
      (chat-wiki-log-append
       'ingest
       (format "Created %s from %s"
               (file-name-nondirectory page-path)
               source-filename))
      (message "Ingested: %s -> %s" source-path page-path)
      page-path)))


(defcustom chat-wiki-prose-minimum 15
  "How many words or CJK characters make a page more than a skeleton."
  :type 'integer
  :group 'chat-wiki)

(defun chat-wiki--page-has-prose-p (body)
  "Return non-nil when BODY has content and not only headings.

Measured over what is left once headings, list markers and blank lines are
removed, counted in the same units `chat-wiki--tokenize' uses: words for
alphabetic scripts, characters for CJK.

Counted in characters before, which is not a comparable amount of writing
across scripts -- a CJK character carries roughly what a short word does,
so forty characters is a sentence in English and a paragraph in Chinese.
A page written in Chinese had to say two or three times as much as an
English one to stop being reported empty.

The check before that searched for the words TODO, FIXME, stub and
placeholder, which flagged any page that discussed them -- a wiki about
software being exactly where those words legitimately appear."
  (and body
       (let ((prose (replace-regexp-in-string
                     "^[ \t]*[-*+][ \t]*$" ""
                     (replace-regexp-in-string "^#+.*$" "" body))))
         (>= (length (chat-wiki--tokenize prose))
             chat-wiki-prose-minimum))))

(defun chat-wiki--link-target (link)
  "Return the page LINK points at, as a slug, ignoring any anchor."
  (chat-wiki--slugify (car (split-string link "#"))))

(defun chat-wiki--scan ()
  "Read every page once and return what the checks need.

Each element is a plist with :title, :path, :type, :body and :links.

One read per page, rather than one per page per check.  The three checks
each used to walk the whole wiki -- and the orphan check called
`chat-wiki--find-backlinks', which itself reads every file -- so linting
cost O(pages squared) full-text reads.  Fine for a wiki built by hand,
not for one a model can write to in a loop."
  (let ((pages nil))
    (dolist (type-pair chat-wiki--page-types)
      (let ((dir (expand-file-name (cdr type-pair) chat-wiki-root)))
        (when (file-directory-p dir)
          (dolist (file (directory-files dir t "\\.md$"))
            (when (file-readable-p file)
              (condition-case nil
                  (let* ((page (chat-wiki-read-page file))
                         (body (or (plist-get page :body) "")))
                    (push (list :title (plist-get page :title)
                                :path file
                                :type (car type-pair)
                                :body body
                                :links (chat-wiki--extract-wikilinks body))
                          pages))
                (error nil)))))))
    (nreverse pages)))

(defun chat-wiki--page-names (page)
  "Return the slugs PAGE answers to.

Its title, and its filename, which for a source is a date followed by the
slug and so is not the same string."
  (delete-dups
   (list (chat-wiki--slugify (or (plist-get page :title) ""))
         (file-name-base (plist-get page :path)))))

(defun chat-wiki--identity (page)
  "Return PAGE without its body, for reporting."
  (list :title (plist-get page :title)
        :path (plist-get page :path)
        :type (plist-get page :type)))

(defun chat-wiki-lint ()
  "Run wiki health check, report issues.
Returns list of issues found."
  (interactive)
  (let* ((pages (chat-wiki--scan))
         (known (make-hash-table :test 'equal))
         (linked (make-hash-table :test 'equal))
         (issues nil))
    ;; Two indexes over the one scan: what exists, and what is pointed at.
    (dolist (page pages)
      (dolist (name (chat-wiki--page-names page))
        (puthash name page known))
      (dolist (link (plist-get page :links))
        (puthash (chat-wiki--link-target link) t linked)))
    (dolist (page pages)
      (let ((identity (chat-wiki--identity page))
            (title (or (plist-get page :title) "")))
        ;; Orphans: nothing links here.  Sources are entry points, so they
        ;; are not expected to have anything pointing at them.
        (unless (or (eq (plist-get page :type) 'sources)
                    (seq-find (lambda (name) (gethash name linked))
                              (chat-wiki--page-names page)))
          (push `(:type orphan
                        :page ,identity
                        :message ,(format "%s has no backlinks" title))
                issues))
        ;; Broken links: pointing at a page that is not there.
        (dolist (link (plist-get page :links))
          (unless (gethash (chat-wiki--link-target link) known)
            (push `(:type broken-link
                          :page ,identity
                          :link ,link
                          :message ,(format "Broken link [[%s]] in %s"
                                            link title))
                  issues)))
        ;; Skeletons: headings and nothing under them.
        (unless (chat-wiki--page-has-prose-p (plist-get page :body))
          (push `(:type empty
                        :page ,identity
                        :message ,(format "%s has headings but no content"
                                          title))
                issues))))
    ;; Remove duplicates and sort
    (setq issues (delete-dups issues))
    (setq issues (sort issues (lambda (a b)
                                (string< (symbol-name (plist-get a :type))
                                         (symbol-name (plist-get b :type))))))
    ;; Log and report
    (chat-wiki-log-append
     'lint
     (format "Found %d issues" (length issues)))
    (when (called-interactively-p 'interactive)
      (with-current-buffer (get-buffer-create "*Wiki Lint Report*")
        (erase-buffer)
        (insert (format "Wiki Lint Report - %s\n\n" (chat-wiki--now-string)))
        (insert (format "Total pages: %d\n" (length pages)))
        (insert (format "Issues found: %d\n\n" (length issues)))
        (if (null issues)
            (insert "✓ No issues found!\n")
          (let ((current-type nil))
            (dolist (issue issues)
              (let ((type (plist-get issue :type)))
                (unless (eq type current-type)
                  (setq current-type type)
                  (insert (format "\n## %s\n\n" (upcase (symbol-name type)))))
                (insert (format "• %s\n" (plist-get issue :message)))))))
        (goto-char (point-min))
        (pop-to-buffer (current-buffer))))
    issues))

;; ------------------------------------------------------------------
;; Interactive Commands
;; ------------------------------------------------------------------




;;;###autoload
(defun chat-wiki-browse-index ()
  "Open index.md in a buffer."
  (interactive)
  (let ((index-path (chat-wiki-index-update)))
    (find-file index-path)))

;;;###autoload
(defun chat-wiki-browse-log ()
  "Open log.md in a buffer."
  (interactive)
  (let ((log-path (chat-wiki--log-path)))
    (unless (file-exists-p log-path)
      (chat-wiki-log-append 'init "Log created"))
    (find-file log-path)))


;;;###autoload
(defun chat-wiki-find-page ()
  "Find and open a wiki page using completing-read.
Shows preview of page content."
  (interactive)
  (let* ((pages (chat-wiki-list-pages))
         (choices (mapcar (lambda (p)
                            (cons (format "%s (%s) [%s]"
                                          (plist-get p :title)
                                          (symbol-name (plist-get p :type))
                                          (plist-get p :date))
                                  p))
                          pages))
         (selection (completing-read
                     "Wiki page: "
                     choices
                     nil t))
         (page (cdr (assoc selection choices))))
    (when page
      (find-file (plist-get page :path)))))

;;;###autoload
(defun chat-wiki-show-backlinks ()
  "Show backlinks for the current wiki page."
  (interactive)
  (if (and buffer-file-name
           (string-prefix-p (expand-file-name chat-wiki-root)
                            (expand-file-name buffer-file-name)))
      (let* ((page (chat-wiki-read-page buffer-file-name))
             (title (plist-get page :title))
             (backlinks (chat-wiki--find-backlinks title)))
        (if (null backlinks)
            (message "No backlinks found for: %s" title)
          (with-current-buffer (get-buffer-create "*Wiki Backlinks*")
            (erase-buffer)
            (insert (format "Backlinks to: %s\n\n" title))
            (dolist (link backlinks)
              (let* ((linked-page (chat-wiki-read-page link))
                     (linked-title (plist-get linked-page :title)))
                (insert (format "• %s\n  %s\n\n" linked-title link))))
            (goto-char (point-min))
            (pop-to-buffer (current-buffer)))))
    (message "Not in a wiki page")))

;; ------------------------------------------------------------------
;; Chat.el Integration Helpers
;; ------------------------------------------------------------------

(defun chat-wiki-get-context-for-query (question &optional max-pages)
  "Get wiki context for QUESTION suitable for LLM prompting.
Returns a string with relevant page content."
  (let* ((matches (chat-wiki-index-search question))
         (pages (seq-take matches (or max-pages 3)))
         (context-parts nil))
    (dolist (page pages)
      (let ((page-data (chat-wiki-read-page (plist-get page :path))))
        (push (format "### %s\n%s\n"
                      (plist-get page-data :title)
                      (plist-get page-data :body))
              context-parts)))
    (if context-parts
        (concat "Relevant wiki pages:\n\n"
                (mapconcat #'identity (nreverse context-parts) "\n---\n"))
      nil)))

(defun chat-wiki--resolve-page (name)
  "Return the path of the page called NAME, or nil.

Matched on the title as written or on the slug, and for sources also on
the slug at the end, since those are filed under a date."
  (let ((slug (chat-wiki--slugify name)))
    (catch 'found
      (dolist (page (chat-wiki-list-pages))
        (let* ((path (plist-get page :path))
               (base (file-name-base path)))
          (when (or (equal (plist-get page :title) name)
                    (equal base slug)
                    (string-suffix-p (concat "-" slug) base))
            (throw 'found path))))
      nil)))

(defun chat-wiki--report (format-string &rest args)
  "Show FORMAT-STRING with ARGS where the reader is looking.

In the chat buffer when there is one, so the answer lands in the
transcript beside the command that asked for it; in the echo area
otherwise, which is where `M-x' callers are looking."
  (let ((text (apply #'format format-string args)))
    (if (and (fboundp 'chat-ui--insert-system-message)
             (derived-mode-p 'chat-mode))
        (chat-ui--insert-system-message text)
      (message "%s" text))))

;; ------------------------------------------------------------------
;; The /wiki command
;; ------------------------------------------------------------------
;;
;; One command with subcommands rather than `/wiki-ingest', `/wiki-query'
;; and three more.  Five top-level entries for one feature crowd the
;; completion list every other command shares, and a common prefix is a
;; namespace that the parser does not know is a namespace: it cannot
;; complete the second half, cannot report an unknown one usefully, and
;; cannot localize the verb without inventing five more aliases.

(defconst chat-wiki--subcommands
  '(("index"  . chat-wiki--sub-index)
    ("log"    . chat-wiki--sub-log)
    ("lint"   . chat-wiki--sub-lint)
    ("search" . chat-wiki--sub-search)
    ("find"   . chat-wiki--sub-find)
    ("new"    . chat-wiki--sub-new)
    ("ingest" . chat-wiki--sub-ingest)
    ("ask"    . chat-wiki--sub-ask))
  "What each `/wiki' subcommand runs.

The handler takes the rest of the line, which may be empty.")

(defconst chat-wiki--subcommand-aliases
  '(("索引" . "index")
    ("日志" . "log")
    ("检查" . "lint")
    ("搜索" . "search")
    ("查找" . "find")
    ("新建" . "new")
    ("导入" . "ingest")
    ("问答" . "ask")
    ("询问" . "ask")
    ("query" . "ask")
    ("q" . "ask")
    ("s" . "search"))
  "Other spellings of a subcommand, localized or abbreviated.

Kept here rather than in `chat-i18n-aliases', which is the slash command
namespace: putting a subcommand there would offer it in the completion of
top-level commands, where it means nothing.")

(defun chat-wiki-subcommand-names ()
  "Return the canonical `/wiki' subcommand names."
  (mapcar #'car chat-wiki--subcommands))

(defun chat-wiki--usage ()
  "Return the `/wiki' usage text."
  (chat-i18n
   'wiki-usage
   (concat "Usage: /wiki <subcommand>\n"
           "  index             open the generated index\n"
           "  log               open the operation log\n"
           "  lint              report orphans, broken links, empty pages\n"
           "  search <text>     list pages matching text\n"
           "  find              pick a page to open\n"
           "  new <type> <name> create a page\n"
           "  ingest <file>     add a document and have it summarized\n"
           "  ask <question>    answer using the wiki")))

(defun chat-wiki-dispatch (arg)
  "Run the `/wiki' subcommand at the head of ARG.

The subcommand name belongs to this program's vocabulary, so it folds
from fullwidth, matches case-insensitively and accepts a localized alias.
What follows it is the subcommand's own argument and is passed on
untouched: a path, a title or a question is data, and folding data is how
you corrupt it."
  (let* ((text (string-trim (or arg "")))
         (split (string-match "[ \t]" text))
         (head (if split (substring text 0 split) text))
         (rest (if split (string-trim (substring text split)) ""))
         (name (downcase (chat-command-fold-name head)))
         (canonical (or (cdr (assoc name chat-wiki--subcommand-aliases)) name))
         (handler (cdr (assoc canonical chat-wiki--subcommands))))
    (cond
     ((string-empty-p name)
      (chat-wiki--report "%s" (chat-wiki--usage)))
     ((null handler)
      (chat-wiki--report
       "%s\n%s"
       (chat-i18n 'wiki-unknown-subcommand "No /wiki subcommand called %s."
                  head)
       (chat-wiki--usage)))
     (t (funcall handler rest)))))

(defun chat-wiki--sub-index (_arg)
  "Regenerate the index and open it."
  (find-file (chat-wiki-index-update)))

(defun chat-wiki--sub-log (_arg)
  "Open the operation log."
  (chat-wiki-browse-log))

(defun chat-wiki--sub-lint (_arg)
  "Report what the health check found."
  (let ((issues (chat-wiki-lint)))
    (if (null issues)
        (chat-wiki--report "%s" (chat-i18n 'wiki-lint-clean "Wiki: no issues."))
      (chat-wiki--report
       "%s\n%s"
       (chat-i18n 'wiki-lint-found "Wiki: %d issues." (length issues))
       (mapconcat (lambda (issue) (format "  - %s" (plist-get issue :message)))
                  (seq-take issues 10) "\n")))))

(defun chat-wiki--sub-search (arg)
  "List the pages matching ARG."
  (if (string-empty-p arg)
      (chat-wiki--report "%s" (chat-i18n 'wiki-search-usage
                                         "Usage: /wiki search <text>"))
    (let ((pages (chat-wiki-index-search arg)))
      (if (null pages)
          (chat-wiki--report "%s" (chat-i18n 'wiki-search-none
                                             "Wiki: nothing matches %s." arg))
        (chat-wiki--report
         "%s\n%s"
         (chat-i18n 'wiki-search-found "Wiki: %d pages match %s."
                    (length pages) arg)
         (mapconcat (lambda (page)
                      (format "  - %s (%s)"
                              (plist-get page :title)
                              (symbol-name (plist-get page :type))))
                    (seq-take pages 10) "\n"))))))

(defun chat-wiki--sub-find (_arg)
  "Pick a page and open it."
  (chat-wiki-find-page))

(defun chat-wiki--sub-new (arg)
  "Create a page, ARG being a type followed by a name."
  (let* ((split (string-match "[ \t]" (string-trim arg)))
         (text (string-trim arg))
         (type-token (if split (substring text 0 split) text))
         ;; The name is data: whatever the user typed is the title.
         (name (if split (string-trim (substring text split)) ""))
         (type (intern-soft (downcase (chat-command-fold-name type-token)))))
    (cond
     ((or (string-empty-p type-token) (string-empty-p name))
      (chat-wiki--report
       "%s" (chat-i18n 'wiki-new-usage "Usage: /wiki new <%s> <name>"
                       (mapconcat (lambda (p) (symbol-name (car p)))
                                  chat-wiki--page-types "|"))))
     ((null (assq type chat-wiki--page-types))
      (chat-wiki--report
       "%s" (chat-i18n 'wiki-new-bad-type "No such page type: %s. One of: %s."
                       type-token
                       (mapconcat (lambda (p) (symbol-name (car p)))
                                  chat-wiki--page-types ", "))))
     (t
      (condition-case err
          (let ((path (chat-wiki-create-page type name)))
            (chat-wiki--report "%s" (chat-i18n 'wiki-created "Wiki: created %s."
                                               (file-name-nondirectory path)))
            (find-file path))
        (error (chat-wiki--report "%s" (error-message-string err))))))))

(defun chat-wiki--sub-ingest (arg)
  "Add the document at ARG, then have the model summarize the page.

The summary is the model's work, asked for as a recorded turn: the
request and the tool calls that answer it both end up on screen, where
before this the page was created with `Key takeaway 1' in it and nothing
ever filled it in."
  (let ((path (and (not (string-empty-p arg)) (expand-file-name arg))))
    (cond
     ((null path)
      (chat-wiki--report "%s" (chat-i18n 'wiki-ingest-usage
                                         "Usage: /wiki ingest <file>")))
     ((not (file-readable-p path))
      (chat-wiki--report "%s" (chat-i18n 'wiki-ingest-missing
                                         "Cannot read %s." path)))
     (t
      (condition-case err
          (let ((page (chat-wiki-ingest path (file-name-base path))))
            (chat-wiki--report
             "%s" (chat-i18n 'wiki-ingested "Wiki: ingested %s."
                             (file-name-nondirectory page)))
            (if (fboundp 'chat-ui--send-user-message)
                (chat-ui--send-user-message
                 (chat-i18n
                  'wiki-ingest-request
                  (concat "Read the wiki page \"%s\" and fill in its Summary, "
                          "Extracted Entities and Related Concepts from its "
                          "Full Content, using the wiki tools. Link entities "
                          "and concepts as [[wikilinks]] and create the pages "
                          "you link to.")
                  (file-name-base page)))
              (chat-wiki--report
               "%s" (chat-i18n 'wiki-no-surface
                               "Open a chat buffer to have it summarized."))))
        (error (chat-wiki--report "%s" (error-message-string err))))))))

(defun chat-wiki--sub-ask (arg)
  "Ask the model ARG with the wiki available to it.

Retrieval is left to the tools rather than pasted in here.  Two reasons:
the pages the model actually consulted show up as tool calls instead of
being invisible, and a long page cannot silently crowd the rest of the
context out of the request."
  (cond
   ((string-empty-p arg)
    (chat-wiki--report "%s" (chat-i18n 'wiki-ask-usage
                                       "Usage: /wiki ask <question>")))
   ((not (fboundp 'chat-ui--send-user-message))
    (chat-wiki--report "%s" (chat-i18n 'wiki-no-surface
                                       "Open a chat buffer to ask.")))
   (t
    (chat-ui--send-user-message
     (format "%s\n\n%s" arg
             (chat-i18n 'wiki-ask-note
                        (concat "(Consult the wiki with wiki_search and "
                                "wiki_read before answering.)")))))))

;; ------------------------------------------------------------------
;; Tools
;; ------------------------------------------------------------------
;;
;; How the model reaches the wiki.  Deliberately not an index in the
;; system prompt, which is how `chat-knowledge.el' works: that store is
;; bounded by what one run learns, while a wiki is meant to grow for
;; years, and a growing block in the fixed region of the context steadily
;; shrinks the room left to work in.  Tools cost nothing until used.

(defun chat-wiki-tool-search (text)
  "Return the titles of wiki pages matching TEXT."
  (let ((pages (seq-take (chat-wiki-index-search (or text "")) 20)))
    (if (null pages)
        (format "No wiki page matches %s." text)
      (concat "Matching wiki pages:\n"
              (mapconcat (lambda (page)
                           (format "- %s (%s)"
                                   (plist-get page :title)
                                   (symbol-name (plist-get page :type))))
                         pages "\n")))))

(defun chat-wiki-tool-read (name)
  "Return the body of the wiki page called NAME."
  (let ((path (chat-wiki--resolve-page (or name ""))))
    (if (null path)
        (format "No wiki page called %s." name)
      (let ((page (chat-wiki-read-page path)))
        (format "# %s\n\n%s"
                (plist-get page :title)
                (plist-get page :body))))))

(defun chat-wiki-tool-write (type name content &optional mode)
  "Create or update the wiki page called NAME of TYPE with CONTENT.

MODE \"append\" adds to the page instead of replacing it.  The index is
not regenerated here: it is a full read of every page, and a run writing
ten pages would pay for it ten times.  `/wiki index' regenerates it."
  (cond
   ((or (null name) (string-empty-p (string-trim name)))
    "A wiki page needs a name.")
   ((or (null content) (string-empty-p content))
    "A wiki page needs content.")
   (t
    (let* ((existing (chat-wiki--resolve-page name))
           (kind (intern-soft (downcase (chat-command-fold-name
                                         (or type "concepts"))))))
      (cond
       (existing
        (let ((body (if (equal mode "append")
                        (concat (plist-get (chat-wiki-read-page existing) :body)
                                "\n" content)
                      content)))
          (chat-wiki-update-page existing body)
          (format "Updated %s." (file-relative-name existing chat-wiki-root))))
       ((null (assq kind chat-wiki--page-types))
        (format "No such page type: %s. One of: %s." type
                (mapconcat (lambda (p) (symbol-name (car p)))
                           chat-wiki--page-types ", ")))
       (t
        ;; Given a title and a body, not a file.  `chat-wiki-create-page'
        ;; supplies the frontmatter, so the model does not have to.
        (let ((path (chat-wiki-create-page kind name content)))
          (format "Created %s."
                  (file-relative-name path chat-wiki-root)))))))))

;;;###autoload
(defun chat-wiki-register-tools ()
  "Register the wiki tools."
  (when (fboundp 'chat-tool-forge-register)
    (chat-tool-forge-register
     (make-chat-forged-tool
      :id 'wiki_search :name "Wiki Search"
      :description
      (concat "Find wiki pages matching some text. Returns titles and "
              "types, not bodies; read a page to see its content.")
      :language 'elisp
      :parameters '((:name "text" :type "string" :required t))
      :owner 'wiki :sensitivity 'project :effects '(read)
      :compiled-function #'chat-wiki-tool-search
      :is-active t :usage-count 0))
    (chat-tool-forge-register
     (make-chat-forged-tool
      :id 'wiki_read :name "Wiki Read"
      :description "Read one wiki page by title."
      :language 'elisp
      :parameters '((:name "name" :type "string" :required t))
      :owner 'wiki :sensitivity 'project :effects '(read)
      :compiled-function #'chat-wiki-tool-read
      :is-active t :usage-count 0))
    (chat-tool-forge-register
     (make-chat-forged-tool
      :id 'wiki_write :name "Wiki Write"
      :description
      (concat "Create or update a wiki page. TYPE is one of sources, "
              "entities, concepts, comparisons, synthesis and is used only "
              "when creating. Link related pages as [[Title]]. Use MODE "
              "\"append\" to extend a page rather than replace it.")
      :language 'elisp
      :parameters '((:name "type" :type "string" :required t)
                    (:name "name" :type "string" :required t)
                    (:name "content" :type "string" :required t)
                    (:name "mode" :type "string" :required nil))
      :owner 'wiki :sensitivity 'project :effects '(write)
      :compiled-function #'chat-wiki-tool-write
      :is-active t :usage-count 0))))

;; ------------------------------------------------------------------
;; Initialization
;; ------------------------------------------------------------------

(defun chat-wiki-initialize ()
  "Initialize the wiki system.
Creates necessary directories if they don't exist."
  (interactive)
  (chat-wiki--ensure-directory chat-wiki-root)
  (dolist (type-pair chat-wiki--page-types)
    (chat-wiki--ensure-directory
     (expand-file-name (cdr type-pair) chat-wiki-root)))
  ;; Create index and log if they don't exist
  (unless (file-exists-p (chat-wiki--index-path))
    (chat-wiki-index-update))
  (unless (file-exists-p (chat-wiki--log-path))
    (chat-wiki-log-append 'init "Wiki initialized"))
  (message "Wiki initialized at: %s" chat-wiki-root))

;; Nothing runs on load.  This file used to call `chat-wiki-initialize'
;; when a `wiki' directory happened to exist next to wherever Emacs was
;; started, so merely loading chat.el created directories and wrote two
;; files -- in a directory the user had not named, for a feature they had
;; not asked for.  Every writer below ensures its own directory, so first
;; use is early enough.

;; ------------------------------------------------------------------
;; Provide
;; ------------------------------------------------------------------

(provide 'chat-wiki)
;;; chat-wiki.el ends here
