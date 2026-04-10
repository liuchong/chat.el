;;; chat-wiki.el --- LLM Wiki pattern implementation for chat.el -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;; Author: chat.el contributors
;; Keywords: chat, wiki, knowledge, llm

;; This file is not part of GNU Emacs.

;;; Commentary:

;; This module implements Karpathy's LLM Wiki pattern for chat.el.
;; It provides knowledge management through a structured wiki system
;; with sources, entities, concepts, and Obsidian-compatible linking.
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

;;; Code:

(require 'cl-lib)
(require 'seq)

;; ------------------------------------------------------------------
;; Customization
;; ------------------------------------------------------------------

(defgroup chat-wiki nil
  "LLM Wiki pattern for chat.el."
  :group 'chat
  :prefix "chat-wiki-")

(defcustom chat-wiki-root
  (expand-file-name "wiki" (or (bound-and-true-p chat-root-directory)
                               default-directory))
  "Root directory for the wiki."
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

(defun chat-wiki--slugify (title)
  "Convert TITLE to a URL-friendly slug."
  (downcase
   (replace-regexp-in-string
    "[^a-z0-9]+" "-"
    (replace-regexp-in-string
     "'" ""
     (replace-regexp-in-string
      "[^[:ascii:]]" ""
      title)))))

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
Returns a cons cell (frontmatter-alist . body-string)."
  (if (string-match "^---\\s-*\n\\(.*?\\)\\n---\\s-*\n\\(.*\\)" content)
      (let* ((yaml-text (match-string 1 content))
             (body (match-string 2 content))
             (frontmatter nil))
        ;; Parse simple key: value pairs
        (dolist (line (split-string yaml-text "\n"))
          (when (string-match "^\\([^:]+\\):\\s-*\\(.+\\)" line)
            (let ((key (intern (downcase (match-string 1 line))))
                  (value (string-trim (match-string 2 line))))
              ;; Remove quotes if present
              (when (string-match "^\"\\(.*\\)\"$" value)
                (setq value (match-string 1 value)))
              (when (string-match "^'\\(.*\\)'$" value)
                (setq value (match-string 1 value)))
              (push (cons key value) frontmatter))))
        (cons (nreverse frontmatter) body))
    (cons nil content)))

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
  "Return regexp pattern for WikiLinks [[Like This]]."
  "\\[\\[\\([^\\]]+\\)\\]\\]")

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
  "Find all pages linking to TARGET.
If TYPE is specified, only search that page type directory.
Returns list of file paths."
  (let ((target-pattern (format "[[%s]]" target))
        (dirs (if type
                  (list (expand-file-name
                         (cdr (assoc type chat-wiki--page-types))
                         chat-wiki-root))
                (mapcar (lambda (p) (expand-file-name (cdr p) chat-wiki-root))
                        chat-wiki--page-types)))
        (backlinks nil))
    (dolist (dir dirs)
      (when (file-directory-p dir)
        (dolist (file (directory-files dir t "\\.md$"))
          (when (and (file-readable-p file)
                     (not (file-directory-p file)))
            (with-temp-buffer
              (insert-file-contents file)
              (when (search-forward target-pattern nil t)
                (push file backlinks)))))))
    (delete-dups (nreverse backlinks))))

;; ------------------------------------------------------------------
;; Page Management
;; ------------------------------------------------------------------

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
      (insert (or content
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
         (title (or (cdr (assoc 'title frontmatter))
                    (progn
                      (string-match "^# \\(.+\\)$" body)
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

(defun chat-wiki-page-exists-p (name &optional type)
  "Check if page with NAME exists.
If TYPE is specified, only check that type."
  (let ((slug (chat-wiki--slugify name)))
    (catch 'found
      (dolist (type-pair (if type
                             (list (cons type (cdr (assoc type chat-wiki--page-types))))
                           chat-wiki--page-types))
        (let ((dir (expand-file-name (cdr type-pair) chat-wiki-root)))
          (when (file-directory-p dir)
            (dolist (file (directory-files dir nil "\\.md$"))
              (when (or (string= (file-name-base file) slug)
                        (string= file (format "%s.md" slug)))
                (throw 'found t))))))
      nil)))

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
          (format "- **Source**: %s\n" (or source-url "TODO: Add source URL"))
          "- **Type**: article\n"
          "- **Projects**: all\n\n"
          "## Summary\n"
          "- Key takeaway 1\n"
          "- Key takeaway 2\n"
          "- Key takeaway 3\n\n"
          "## Extracted Entities\n"
          "- [[entity1]]\n"
          "- [[entity2]]\n\n"
          "## Related Concepts\n"
          "- [[concept1]]\n"
          "- [[concept2]]\n\n"
          "## Integration Notes\n"
          "How this applies to our system...\n"))

(defun chat-wiki--entity-template (name type)
  "Generate entity page template."
  (concat (chat-wiki--write-frontmatter
           `((title . ,name)
             (type . ,type)
             (created . ,(chat-wiki--today-string))))
          (format "# %s\n\n" name)
          "## Basic Info\n"
          (format "- **Type**: %s\n" type)
          (format "- **Created**: %s\n" (chat-wiki--today-string))
          "- **Related**: [[link1]], [[link2]]\n\n"
          "## Description\n"
          "What is this entity...\n\n"
          "## In Our System\n"
          "How it relates to chat/d/chat.el...\n\n"
          "## Sources\n"
          "- [[source1]]\n"
          "- [[source2]]\n"))

(defun chat-wiki--concept-template (name)
  "Generate concept page template."
  (concat (chat-wiki--write-frontmatter
           `((title . ,name)
             (type . "concept")
             (created . ,(chat-wiki--today-string))))
          (format "# %s\n\n" name)
          "## Definition\n"
          "Clear definition of the concept...\n\n"
          "## In d/ (Rust)\n"
          "Implementation in Rust...\n\n"
          "## In chat.zig (Zig)\n"
          "Implementation in Zig...\n\n"
          "## In chat.el (Elisp)\n"
          "Implementation in Emacs Lisp...\n\n"
          "## Comparisons\n"
          "- [[comparison-concept-a-vs-b]]\n\n"
          "## Sources\n"
          "- [[source1]]\n"
          "- [[source2]]\n"))

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
      (insert (chat-wiki--write-frontmatter
               '((title . "Wiki Index")
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
  "Search index for pages matching QUERY.
Returns list of matching page plists."
  (let ((pages (chat-wiki-list-pages))
        (matches nil)
        (query-re (concat "\\(" (mapconcat #'regexp-quote
                                            (split-string query)
                                            "\\|") "\\)")))
    (dolist (page pages)
      (when (or (string-match-p query-re (plist-get page :title))
                (let ((content (ignore-errors
                                 (plist-get (chat-wiki-read-page (plist-get page :path))
                                            :body))))
                  (and content (string-match-p query-re content))))
        (push page matches)))
    (nreverse matches)))

;; ------------------------------------------------------------------
;; Log Management
;; ------------------------------------------------------------------

(defun chat-wiki-log-append (operation description)
  "Append entry to log.md.
OPERATION is a symbol like `ingest', `query', `lint', etc.
DESCRIPTION is the log message."
  (chat-wiki--ensure-directory chat-wiki-root)
  (let ((log-path (chat-wiki--log-path))
        (entry (format "## [%s] %s | %s\n\n"
                       (chat-wiki--now-string)
                       (symbol-name operation)
                       description)))
    (if (file-exists-p log-path)
        (with-temp-buffer
          (insert-file-contents log-path)
          (goto-char (point-min))
          (insert entry)
          (write-file log-path))
      (with-temp-file log-path
        (insert (chat-wiki--write-frontmatter
                 '((title . "Wiki Log")
                   (type . "log"))))
        (insert "# Wiki Log\n\n")
        (insert "Chronological record of wiki operations.\n\n")
        (insert entry)))
    log-path))

(defun chat-wiki-log-recent (&optional n)
  "Get recent N log entries (default 20).
Returns list of entry strings."
  (let ((log-path (chat-wiki--log-path))
        (n (or n 20)))
    (if (file-exists-p log-path)
        (with-temp-buffer
          (insert-file-contents log-path)
          (let ((entries nil)
                (count 0))
            (goto-char (point-min))
            (while (and (< count n)
                        (re-search-forward "^## \\[[0-9]" nil t))
              (let ((start (match-beginning 0))
                    (end (or (save-excursion
                              (re-search-forward "^## \\[[0-9]" nil t)
                              (match-beginning 0))
                             (point-max))))
                (push (string-trim (buffer-substring start end)) entries)
                (setq count (1+ count))
                (goto-char start)
                (forward-line 1)))
            (nreverse entries)))
      nil)))

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

(defun chat-wiki-query (question)
  "Query the wiki with QUESTION, return synthesized answer.
This is a basic implementation - returns relevant pages."
  (interactive "sQuestion: ")
  (let* ((matches (chat-wiki-index-search question))
         (relevant-pages (seq-take matches 5)))
    (if (null relevant-pages)
        (progn
          (message "No relevant pages found for: %s" question)
          nil)
      ;; Log the query
      (chat-wiki-log-append
       'query
       (format "%s (found %d pages)" question (length relevant-pages)))
      ;; Return relevant page info
      (let ((result `(:question ,question
                                :pages ,relevant-pages
                                :summary ,(mapconcat
                                           (lambda (p)
                                             (format "- %s" (plist-get p :title)))
                                           relevant-pages
                                           "\n"))))
        (when (called-interactively-p 'interactive)
          (with-current-buffer (get-buffer-create "*Wiki Query Result*")
            (erase-buffer)
            (insert (format "Query: %s\n\n" question))
            (insert "Relevant pages:\n")
            (dolist (page relevant-pages)
              (insert (format "\n• %s (%s)\n  %s\n"
                              (plist-get page :title)
                              (symbol-name (plist-get page :type))
                              (plist-get page :path))
                      (when (plist-get page :date)
                        (format "  Date: %s\n" (plist-get page :date)))))
            (goto-char (point-min))
            (pop-to-buffer (current-buffer))))
        result))))

(defun chat-wiki-lint ()
  "Run wiki health check, report issues.
Returns list of issues found."
  (interactive)
  (let ((issues nil)
        (pages (chat-wiki-list-pages)))
    ;; Check for orphan pages (no backlinks)
    (dolist (page pages)
      (let* ((title (plist-get page :title))
             (backlinks (chat-wiki--find-backlinks title)))
        (when (and (null backlinks)
                   (not (eq (plist-get page :type) 'sources)))
          (push `(:type orphan
                         :page ,page
                         :message ,(format "%s has no backlinks"
                                           title))
                issues))))
    ;; Check for broken WikiLinks
    (dolist (page pages)
      (let* ((content (plist-get (chat-wiki-read-page (plist-get page :path)) :body))
             (links (chat-wiki--extract-wikilinks content)))
        (dolist (link links)
          (unless (or (chat-wiki-page-exists-p link)
                      ;; Allow links with anchors
                      (and (string-match-p "#" link)
                           (chat-wiki-page-exists-p
                            (car (split-string link "#")))))
            (push `(:type broken-link
                           :page ,page
                           :link ,link
                           :message ,(format "Broken link [[%s]] in %s"
                                             link
                                             (plist-get page :title)))
                  issues)))))
    ;; Check for empty pages
    (dolist (page pages)
      (let ((body (plist-get (chat-wiki-read-page (plist-get page :path)) :body)))
        (when (or (null body)
                  (string-match-p "^\\s-*$" body)
                  (string-match-p "TODO\\|FIXME\\|stub\\|placeholder"
                                  (downcase body)))
          (push `(:type empty
                         :page ,page
                         :message ,(format "%s appears empty or stub"
                                           (plist-get page :title)))
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
(defun chat-wiki-ingest-file (source-path title)
  "Interactively ingest SOURCE-PATH as a wiki source with TITLE."
  (interactive
   (let ((file (read-file-name "Source file to ingest: ")))
     (list file
           (read-string "Title: "
                        (file-name-base file)))))
  (chat-wiki-ingest source-path title)
  (when (y-or-n-p "Open the new page? ")
    (let* ((slug (chat-wiki--slugify title))
           (filepath (expand-file-name
                      (format "%s-%s.md" (chat-wiki--today-string) slug)
                      (expand-file-name "sources" chat-wiki-root))))
      (find-file filepath))))

;;;###autoload
(defun chat-wiki-query-interactive (question)
  "Interactively query the wiki with QUESTION."
  (interactive "sWiki query: ")
  (chat-wiki-query question))

;;;###autoload
(defun chat-wiki-lint-interactive ()
  "Interactively run wiki health check."
  (interactive)
  (chat-wiki-lint))

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
(defun chat-wiki-create-page-interactive (type name)
  "Interactively create a new wiki page of TYPE with NAME."
  (interactive
   (list (intern
          (completing-read "Page type: "
                           '("entities" "concepts" "comparisons" "synthesis")
                           nil t))
         (read-string "Page name: ")))
  (let ((filepath (chat-wiki-create-page type name)))
    (message "Created: %s" filepath)
    (when (y-or-n-p "Open the new page? ")
      (find-file filepath))))

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

(defun chat-wiki-command-handler (command args)
  "Handle wiki-related chat commands.
COMMAND is the command symbol, ARGS is the argument string.
Returns nil if command not handled."
  (pcase command
    ('wiki-ingest
     (let ((files (split-string args)))
       (dolist (file files)
         (if (file-exists-p file)
             (chat-wiki-ingest file (file-name-base file))
           (message "File not found: %s" file))))
     t)
    ('wiki-query
     (let ((result (chat-wiki-query args)))
       (when result
         (message "Query results in *Wiki Query Result* buffer"))
       t))
    ('wiki-lint
     (chat-wiki-lint)
     t)
    ('wiki-index
     (chat-wiki-browse-index)
     t)
    ('wiki-log
     (chat-wiki-browse-log)
     t)
    (_ nil)))

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

;; Auto-initialize on load if wiki root exists or is configured
(when (or (file-directory-p chat-wiki-root)
          (bound-and-true-p chat-root-directory))
  (chat-wiki-initialize))

;; ------------------------------------------------------------------
;; Provide
;; ------------------------------------------------------------------

(provide 'chat-wiki)
;;; chat-wiki.el ends here
