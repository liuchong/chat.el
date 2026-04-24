;;; chat-files.el --- File operations for AI agent -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;; Author: chat.el contributors
;; Keywords: files, tools, ai

;; This file is not part of GNU Emacs.

;;; Commentary:

;; This module provides file operation capabilities for the AI agent.
;; It wraps Emacs built-in functions with a unified interface suitable
;; for AI tool invocation, including read, search, modify, and transform
;; operations.

;;; Code:

(require 'cl-lib)
(require 'diff)
(require 'seq)
(require 'subr-x)
(require 'chat-tool-forge)

;; ------------------------------------------------------------------
;; Customization
;; ------------------------------------------------------------------

(defgroup chat-files nil
  "File operations for chat.el AI agent."
  :group 'chat)

(defcustom chat-files-max-size (* 1024 1024)
  "Maximum file size in bytes that can be read."
  :type 'integer
  :group 'chat-files)

(defcustom chat-files-allowed-directories
  '("./" "/tmp/" "/var/tmp/")
  "Directories that AI is allowed to access.
Can be overridden per-session."
  :type '(repeat directory)
  :group 'chat-files)

(defcustom chat-files-deny-patterns
  '("\\.gpg$" "\\.key$" "\\.pem$" "\\.p12$" "id_rsa" "\\.env")
  "File patterns that should never be accessed."
  :type '(repeat string)
  :group 'chat-files)

;; ------------------------------------------------------------------
;; Security and Validation
;; ------------------------------------------------------------------

(defun chat-files--existing-ancestor (path)
  "Return the nearest existing ancestor for PATH."
  (let ((current (expand-file-name path)))
    (while (and current
                (not (file-exists-p current))
                (not (string= current "/")))
      (setq current (directory-file-name (file-name-directory current))))
    (if (file-exists-p current)
        current
      "/")))

(defun chat-files--resolved-path (path)
  "Return a normalized PATH with symlinks resolved."
  (let* ((expanded (expand-file-name path))
         (exists (file-exists-p expanded)))
    (if exists
        (file-truename expanded)
      (let* ((ancestor (chat-files--existing-ancestor expanded))
             (ancestor-truename (file-truename ancestor))
             (relative (file-relative-name expanded ancestor)))
        (expand-file-name relative ancestor-truename)))))

(defun chat-files--safe-path-p (path)
  "Check if PATH is safe to access.
Returns nil if path matches deny patterns or is outside allowed directories."
  (let ((expanded (chat-files--resolved-path path)))
    ;; Check deny patterns
    (when (seq-find (lambda (pat)
                      (string-match-p pat expanded))
                    chat-files-deny-patterns)
      (error "Access denied: path matches sensitive file pattern"))
    ;; Check allowed directories
    (unless (seq-find (lambda (dir)
                        (let ((allowed-root (file-name-as-directory
                                             (chat-files--resolved-path dir))))
                          (or (string= expanded (directory-file-name allowed-root))
                              (string-prefix-p allowed-root
                                               (file-name-as-directory expanded)))))
                      chat-files-allowed-directories)
      (error "Access denied: path outside allowed directories"))
    expanded))

(defun chat-files--check-size (path)
  "Check if file at PATH is within size limits."
  (when (> (file-attribute-size (file-attributes path))
           chat-files-max-size)
    (error "File too large: %s exceeds %d bytes"
           path chat-files-max-size)))

;; ------------------------------------------------------------------
;; Basic File Operations
;; ------------------------------------------------------------------

;;;###autoload
(defun chat-files-read (path &optional offset limit encoding)
  "Read content of file at PATH.

OFFSET is the starting position (default 0).
LIMIT is max characters to read (default nil = all).
ENCODING specifies the file encoding (default utf-8).

Returns a plist with :content, :size, :lines, :encoding."
  (let* ((safe-path (chat-files--safe-path-p path))
         (_ (chat-files--check-size safe-path))
         (coding-system (or encoding 'utf-8)))
    (with-temp-buffer
      (let ((coding-system-for-read coding-system))
        (insert-file-contents safe-path))
      (when offset
        (delete-region 1 (min (1+ offset) (point-max))))
      (when limit
        (delete-region (min (1+ limit) (point-max)) (point-max)))
      (let ((content (buffer-string)))
        (list :content content
              :size (length content)
              :lines (count-lines (point-min) (point-max))
              :encoding coding-system
              :path safe-path)))))

;;;###autoload
(defun chat-files-read-lines (path &optional start-line num-lines)
  "Read specific lines from file at PATH.

START-LINE is the first line to read (1-based, default 1).
NUM-LINES is how many lines to read (default nil = to end).

Returns a plist with :lines (list of strings), :start, :end, :total-lines."
  (let* ((safe-path (chat-files--safe-path-p path))
         (requested-start (or start-line 1)))
    (with-temp-buffer
      (insert-file-contents safe-path)
      (let* ((total (count-lines (point-min) (point-max)))
             (start (max 1 (min requested-start (1+ total))))
             (end (if num-lines
                      (min (+ start num-lines -1) total)
                    total))
             (lines '()))
        (goto-char (point-min))
        (forward-line (1- start))
        (dotimes (_ (1+ (- end start)))
          (push (buffer-substring-no-properties
                 (line-beginning-position)
                 (line-end-position))
                lines)
          (forward-line 1))
        (list :lines (nreverse lines)
              :start start
              :end end
              :total-lines total
              :path safe-path)))))

;;;###autoload
(defun chat-files-exists-p (path)
  "Check if file or directory at PATH exists."
  (let ((safe-path (chat-files--safe-path-p path)))
    (list :exists (file-exists-p safe-path)
          :type (cond ((file-directory-p safe-path) 'directory)
                      ((file-regular-p safe-path) 'file)
                      (t 'other))
          :path safe-path)))

;;;###autoload
(defun chat-files-list (directory &optional pattern recursive)
  "List files in DIRECTORY.

PATTERN is an optional regex to filter filenames.
If RECURSIVE is non-nil, list recursively.

Returns a list of plists with :name, :path, :size, :mtime, :type."
  (let* ((safe-dir (chat-files--safe-path-p directory))
         (filter-pattern (or pattern ".*"))
         (files '()))
    (if recursive
        (progn
          (dolist (full-path (directory-files-recursively safe-dir filter-pattern))
            (push (list :name (file-name-nondirectory full-path)
                        :path full-path
                        :size (file-attribute-size (file-attributes full-path))
                        :mtime (file-attribute-modification-time
                                (file-attributes full-path))
                        :type 'file)
                  files))
          (nreverse files))
      (progn
        (dolist (name (directory-files safe-dir nil filter-pattern))
          (unless (member name '("." ".."))
            (let ((full-path (expand-file-name name safe-dir)))
              (push (list :name name
                         :path full-path
                         :size (file-attribute-size
                                (file-attributes full-path))
                         :mtime (file-attribute-modification-time
                                 (file-attributes full-path))
                         :type (if (file-directory-p full-path)
                                  'directory
                                'file))
                    files))))
        (nreverse files)))))

;; ------------------------------------------------------------------
;; File Movement and Organization
;; ------------------------------------------------------------------

;;;###autoload
(defun chat-files-move (source dest &optional overwrite)
  "Move or rename file from SOURCE to DEST.
If OVERWRITE is non-nil, overwrite existing file at DEST."
  (let ((safe-source (chat-files--safe-path-p source))
        (safe-dest (chat-files--safe-path-p dest)))
    (when (and (file-exists-p safe-dest) (not overwrite))
      (error "Destination exists and overwrite is nil: %s" safe-dest))
    (rename-file safe-source safe-dest overwrite)
    (list :source safe-source
          :destination safe-dest
          :operation 'move)))

;;;###autoload
(defun chat-files-copy (source dest &optional overwrite)
  "Copy file from SOURCE to DEST.
If OVERWRITE is non-nil, overwrite existing file at DEST."
  (let ((safe-source (chat-files--safe-path-p source))
        (safe-dest (chat-files--safe-path-p dest)))
    (when (and (file-exists-p safe-dest) (not overwrite))
      (error "Destination exists and overwrite is nil: %s" safe-dest))
    (copy-file safe-source safe-dest overwrite)
    (list :source safe-source
          :destination safe-dest
          :operation 'copy)))

;;;###autoload
(defun chat-files-delete (path &optional recursive)
  "Delete file or directory at PATH.
If RECURSIVE is non-nil and PATH is a directory, delete recursively."
  (let ((safe-path (chat-files--safe-path-p path)))
    (if (file-directory-p safe-path)
        (delete-directory safe-path recursive)
      (delete-file safe-path))
    (list :path safe-path
          :operation 'delete
          :recursive recursive)))

;;;###autoload
(defun chat-files-mkdir (path &optional parents)
  "Create directory at PATH.
If PARENTS is non-nil, create parent directories as needed."
  (let ((safe-path (chat-files--safe-path-p path)))
    (make-directory safe-path parents)
    (list :path safe-path
          :operation 'mkdir
          :parents parents)))

;; ------------------------------------------------------------------
;; Search Operations
;; ------------------------------------------------------------------

;;;###autoload
(defun chat-files-grep (pattern path &optional context-lines)
  "Search for PATTERN in file at PATH.

PATTERN is a regular expression.
CONTEXT-LINES specifies lines of context around each match (default 2).

Returns a list of match plists with :line-num, :content, :context-before, 
:context-after, :match-start, :match-end."
  (let* ((safe-path (chat-files--safe-path-p path))
         (context (or context-lines 2))
         (matches '()))
    (with-temp-buffer
      (insert-file-contents safe-path)
      (goto-char (point-min))
      (let ((line-num 1))
        (while (not (eobp))
          (let* ((line-start (line-beginning-position))
                 (line-end (line-end-position))
                 (line-content (buffer-substring line-start line-end)))
            (when (string-match-p pattern line-content)
              (let* ((match-start (string-match pattern line-content))
                     (match-end (match-end 0)))
                (push (list :line-num line-num
                           :content line-content
                           :match-start match-start
                           :match-end match-end
                           :context-before
                           (chat-files--get-context
                            (current-buffer) line-num context 'before)
                           :context-after
                           (chat-files--get-context
                            (current-buffer) line-num context 'after))
                      matches))))
          (forward-line 1)
          (cl-incf line-num))))
    (list :pattern pattern
          :path safe-path
          :match-count (length matches)
          :matches (nreverse matches))))

(defun chat-files--get-context (buffer line-num num-lines direction)
  "Get NUM-LINES lines of context from BUFFER around LINE-NUM.
DIRECTION is 'before or 'after."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (forward-line (1- line-num))
      (if (eq direction 'before)
          (progn
            (forward-line (- num-lines))
            (buffer-substring (line-beginning-position)
                             (save-excursion
                               (forward-line num-lines)
                               (point))))
        (forward-line 1)
        (buffer-substring (point)
                         (save-excursion
                           (forward-line num-lines)
                           (point)))))))

;;;###autoload
(defun chat-files-find (directory pattern &optional file-pattern)
  "Recursively search for files containing PATTERN in DIRECTORY.

FILE-PATTERN optionally filters by filename regex.
Returns a list of file paths with matches."
  (let* ((safe-dir (chat-files--safe-path-p directory))
         (files (directory-files-recursively
                 safe-dir (or file-pattern ".*")))
         (results '()))
    (dolist (file files)
      (when (and (file-regular-p file)
                 (not (backup-file-name-p file)))
        (with-temp-buffer
          (condition-case nil
              (progn
                (insert-file-contents file)
                (when (re-search-forward pattern nil t)
                  (push file results)))
            (error nil)))))
    (list :directory safe-dir
          :pattern pattern
          :file-pattern file-pattern
          :matches (nreverse results)
          :match-count (length results))))

;; ------------------------------------------------------------------
;; Content Extraction and Slicing
;; ------------------------------------------------------------------

;;;###autoload
(defun chat-files-extract (path start end)
  "Extract content from PATH between START and END positions.
START and END can be:
- Integers (character positions)
- Plists with :line and :column
- Line numbers (if integer and small)

Returns a plist with :content, :start, :end, :length."
  (let* ((safe-path (chat-files--safe-path-p path))
         (start-pos (chat-files--normalize-position start safe-path))
         (end-pos (chat-files--normalize-position end safe-path)))
    (with-temp-buffer
      (insert-file-contents safe-path)
      (let ((content (buffer-substring start-pos end-pos)))
        (list :content content
              :start start-pos
              :end end-pos
              :length (length content)
              :path safe-path)))))

(defun chat-files--normalize-position (pos path)
  "Convert POS to buffer position.
POS can be :line/:column plist, line number, or character position."
  (cond
   ((integerp pos)
    (if (< pos 1000)  ; Assume line number if small
        (with-temp-buffer
          (insert-file-contents path)
          (goto-char (point-min))
          (forward-line (1- pos))
          (point))
      pos))
   ((and (listp pos) (plist-get pos :line))
    (with-temp-buffer
      (insert-file-contents path)
      (goto-char (point-min))
      (forward-line (1- (plist-get pos :line)))
      (when (plist-get pos :column)
        (forward-char (plist-get pos :column)))
      (point)))
   (t (error "Invalid position specification: %s" pos))))

;;;###autoload
(defun chat-files-head (path n)
  "Get first N lines of file at PATH."
  (chat-files-read-lines path 1 n))

;;;###autoload
(defun chat-files-tail (path n)
  "Get last N lines of file at PATH."
  (let* ((safe-path (chat-files--safe-path-p path))
         (total (with-temp-buffer
                  (insert-file-contents safe-path)
                  (count-lines (point-min) (point-max)))))
    (chat-files-read-lines path (max 1 (- total n -1)) n)))

;;;###autoload
(defun chat-files-slice (path line-ranges)
  "Extract specific line ranges from PATH.
LINE-RANGES is a list of (start-line . end-line) cons cells.
Useful for extracting non-contiguous sections.

Returns a plist with :slices (list of :content, :start, :end)."
  (let* ((safe-path (chat-files--safe-path-p path))
         (slices '()))
    (with-temp-buffer
      (insert-file-contents safe-path)
      (dolist (range line-ranges)
        (let ((start (car range))
              (end (cdr range)))
          (goto-char (point-min))
          (forward-line (1- start))
          (let ((slice-start (point)))
            (forward-line (1+ (- end start)))
            (push (list :content (buffer-substring slice-start (point))
                       :start-line start
                       :end-line end)
                  slices)))))
    (list :path safe-path
          :slices (nreverse slices))))

;; ------------------------------------------------------------------
;; Content Modification
;; ------------------------------------------------------------------

;;;###autoload
(defun chat-files-write (path content &optional append encoding)
  "Write CONTENT to file at PATH.
If APPEND is non-nil, append to existing content.
ENCODING specifies the file encoding (default utf-8)."
  (let ((safe-path (chat-files--safe-path-p path))
        (coding-system (or encoding 'utf-8)))
    (make-directory (file-name-directory safe-path) t)
    (with-temp-buffer
      (when (and append (file-exists-p safe-path))
        (insert-file-contents safe-path))
      (goto-char (point-max))
      (insert content)
      (let ((coding-system-for-write coding-system))
        (write-region (point-min) (point-max) safe-path)))
    (list :path safe-path
          :operation (if append 'append 'write)
          :bytes-written (length content)
          :encoding coding-system)))

(defun chat-files--line-number-at-position (content position)
  "Return the 1-based line number for POSITION within CONTENT."
  (1+ (cl-count ?\n (substring content 0 position))))

(defun chat-files--collect-replace-matches (content search regexp)
  "Collect SEARCH matches from CONTENT.
When REGEXP is non-nil, treat SEARCH as a regular expression."
  (with-temp-buffer
    (insert content)
    (goto-char (point-min))
    (let (matches)
      (while (if regexp
                 (re-search-forward search nil t)
               (search-forward search nil t))
        (push (list :start (match-beginning 0)
                    :end (match-end 0)
                    :line (line-number-at-pos (match-beginning 0)))
              matches))
      (nreverse matches))))

(defun chat-files--replace-content (content search replace &optional all expected-count regexp line-hint)
  "Return updated CONTENT after replacing SEARCH with REPLACE."
  (let* ((matches (chat-files--collect-replace-matches content search regexp))
         (filtered (if line-hint
                       (seq-filter (lambda (match)
                                     (= (plist-get match :line) line-hint))
                                   matches)
                     matches))
         (match-count (length filtered))
         (selected (cond
                    ((zerop match-count)
                     (error "Replace failed: no matches for %S" search))
                    (expected-count
                     (unless (= match-count expected-count)
                       (error "Replace failed: expected %d matches for %S but found %d"
                              expected-count search match-count))
                     filtered)
                    (all
                     filtered)
                    ((> match-count 1)
                     (error "Replace failed: %d matches for %S; refine the search or use expected_count/all"
                            match-count search))
                    (t
                     (list (car filtered))))))
    (with-temp-buffer
      (insert content)
      (dolist (match (reverse selected))
        (goto-char (plist-get match :start))
        (if regexp
            (progn
              (re-search-forward search (plist-get match :end) t)
              (replace-match replace nil nil))
          (delete-region (plist-get match :start)
                         (plist-get match :end))
          (goto-char (plist-get match :start))
          (insert replace)))
      (list :content (buffer-string)
            :replacements-made (length selected)
            :match-count match-count))))

(defun chat-files--with-diff (path original-content new-content operation &optional extra)
  "Build a result plist for PATH from ORIGINAL-CONTENT to NEW-CONTENT."
  (let ((diff (chat-files--diff-strings path original-content new-content)))
    (append
     (list :path path
           :operation operation
           :diff diff)
     extra)))

;;;###autoload
(defun chat-files-replace (path search replace &optional all expected-count regexp line-hint)
  "Replace SEARCH pattern with REPLACE text in file at PATH.
SEARCH is matched literally unless REGEXP is non-nil.
When ALL is non-nil, replace all matches.
When EXPECTED-COUNT is non-nil, require exactly that many matches.
When LINE-HINT is non-nil, only consider matches on that line."
  (let* ((safe-path (chat-files--safe-path-p path))
         (original-content (with-temp-buffer
                             (insert-file-contents safe-path)
                             (buffer-string)))
         (result (chat-files--replace-content
                  original-content search replace all expected-count regexp line-hint))
         (new-content (plist-get result :content)))
    (with-temp-file safe-path
      (insert new-content))
    (chat-files--with-diff
     safe-path
     original-content
     new-content
     'replace
     (list :replacements-made (plist-get result :replacements-made)
           :search search
           :replace replace))))

;;;###autoload
(defun chat-files-insert-at (path position text)
  "Insert TEXT at POSITION in file at PATH.
POSITION can be :beginning, :end, a line number, or a character position."
  (let ((safe-path (chat-files--safe-path-p path)))
    (with-temp-buffer
      (insert-file-contents safe-path)
      (cond
       ((eq position :beginning)
        (goto-char (point-min)))
       ((eq position :end)
        (goto-char (point-max)))
       ((integerp position)
        (goto-char (point-min))
        (forward-line (1- position))))
      (insert text)
      (write-region (point-min) (point-max) safe-path))
    (list :path safe-path
          :operation 'insert
          :position position
          :bytes-inserted (length text))))

;;;###autoload
(defun chat-files-patch (path patches)
  "Apply multiple patches to file at PATH.
PATCHES is a list of plists with:
  :search - text/pattern to find
  :replace - replacement text
  :line - optional line number constraint
  :count - optional exact replacement count
  :regexp - optional regular expression flag
  :all - optional replace-all flag.

All patches are applied atomically."
  (let* ((safe-path (chat-files--safe-path-p path))
         (original-content (with-temp-buffer
                             (insert-file-contents safe-path)
                             (buffer-string)))
         (content original-content))
    (dolist (patch patches)
      (let* ((normalized-patch (chat-files--normalize-patch patch))
             (search (plist-get normalized-patch :search))
             (replace (or (plist-get normalized-patch :replace) ""))
             (line (plist-get normalized-patch :line))
             (count (plist-get normalized-patch :count))
             (regexp (plist-get normalized-patch :regexp))
             (all (plist-get normalized-patch :all)))
        (unless search
          (error "Patch is missing search text"))
        (setq content
              (plist-get
               (chat-files--replace-content
                content search replace all count regexp line)
               :content))))
    (with-temp-file safe-path
      (insert content))
    (append
     (chat-files--with-diff safe-path original-content content 'patch)
     (list :patches-applied (length patches)
           :status 'success))))

(defun chat-files--split-content-lines (content)
  "Return CONTENT as a plist with line data."
  (let* ((ends-with-newline (string-suffix-p "\n" content))
         (raw-lines (split-string content "\n" nil)))
    (when (and ends-with-newline raw-lines)
      (setq raw-lines (butlast raw-lines)))
    (list :lines raw-lines
          :ends-with-newline ends-with-newline)))

(defun chat-files--join-content-lines (state)
  "Join line STATE back into a string."
  (let ((body (string-join (plist-get state :lines) "\n")))
    (if (plist-get state :ends-with-newline)
        (concat body "\n")
      body)))

(defun chat-files--patch-operation-content (operation)
  "Return OPERATION content with patch newline semantics."
  (chat-files--join-content-lines
   (list :lines (split-string (plist-get operation :content) "\n")
         :ends-with-newline (plist-get operation :ends-with-newline))))

(defun chat-files--no-newline-marker-p (line)
  "Return non-nil when LINE is a patch no-newline marker."
  (or (equal line "*** End of File")
      (equal line "\\ No newline at end of file")))

(defun chat-files--subsequence-match-positions (haystack needle)
  "Return all positions where NEEDLE appears in HAYSTACK."
  (let ((haystack-length (length haystack))
        (needle-length (length needle))
        positions)
    (cond
     ((zerop needle-length)
      (setq positions nil))
     (t
      (dotimes (index (1+ (- haystack-length needle-length)))
        (when (equal (cl-subseq haystack index (+ index needle-length)) needle)
          (push index positions)))))
    (nreverse positions)))

(defun chat-files--patch-hunk-old-lines (hunk-lines)
  "Return the source-side lines for HUNK-LINES."
  (let (result)
    (dolist (line hunk-lines)
      (let ((prefix (substring line 0 1))
            (text (substring line 1)))
        (when (member prefix '(" " "-"))
          (push text result))))
    (nreverse result)))

(defun chat-files--patch-hunk-new-lines (hunk-lines)
  "Return the destination-side lines for HUNK-LINES."
  (let (result)
    (dolist (line hunk-lines)
      (let ((prefix (substring line 0 1))
            (text (substring line 1)))
        (when (member prefix '(" " "+"))
          (push text result))))
    (nreverse result)))

(defun chat-files--apply-hunk-to-lines (lines hunk-lines)
  "Apply HUNK-LINES to LINES and return updated lines."
  (let* ((old-lines (chat-files--patch-hunk-old-lines hunk-lines))
         (new-lines (chat-files--patch-hunk-new-lines hunk-lines))
         (positions (chat-files--subsequence-match-positions lines old-lines)))
    (cond
     ((null old-lines)
      (error "Patch hunk has no matchable source context"))
     ((null positions)
      (error "Patch hunk could not be applied"))
     ((> (length positions) 1)
      (error "Patch hunk is ambiguous"))
     (t
      (let ((start (car positions)))
        (append (cl-subseq lines 0 start)
                new-lines
                (cl-subseq lines (+ start (length old-lines)))))))))

(defun chat-files--parse-hunk-header (header)
  "Parse unified diff HUNK HEADER."
  (when (string-match
         "^@@ -\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? +\\+\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? @@"
         header)
    (list :old-start (string-to-number (match-string 1 header))
          :old-count (if (match-string 2 header)
                         (string-to-number (match-string 2 header))
                       1)
          :new-start (string-to-number (match-string 3 header))
          :new-count (if (match-string 4 header)
                         (string-to-number (match-string 4 header))
                       1))))

(defun chat-files--choose-hunk-position (positions preferred-start)
  "Choose from POSITIONS using PREFERRED-START when possible."
  (cond
   ((null positions)
    nil)
   ((null preferred-start)
    (if (= (length positions) 1)
        (car positions)
      :ambiguous))
   ((member preferred-start positions)
    preferred-start)
   ((= (length positions) 1)
    (car positions))
   (t
    :ambiguous)))

(defun chat-files--apply-hunk-to-lines-at-position (lines hunk-lines preferred-start)
  "Apply HUNK-LINES to LINES using PREFERRED-START when possible."
  (let* ((old-lines (chat-files--patch-hunk-old-lines hunk-lines))
         (new-lines (chat-files--patch-hunk-new-lines hunk-lines))
         (positions (chat-files--subsequence-match-positions lines old-lines))
         (start (chat-files--choose-hunk-position positions preferred-start)))
    (cond
     ((null old-lines)
      (if (and (integerp preferred-start)
               (>= preferred-start 0)
               (<= preferred-start (length lines)))
          (append (cl-subseq lines 0 preferred-start)
                  new-lines
                  (cl-subseq lines preferred-start))
        (error "Patch hunk has no matchable source context")))
     ((null start)
      (error "Patch hunk could not be applied"))
     ((eq start :ambiguous)
      (error "Patch hunk is ambiguous"))
     (t
      (append (cl-subseq lines 0 start)
              new-lines
              (cl-subseq lines (+ start (length old-lines))))))))

(defun chat-files--parse-apply-patch (patch-text)
  "Parse PATCH-TEXT in codex apply_patch format."
  (let* ((lines (split-string patch-text "\n"))
         (index 0)
         operations)
    (unless (equal (nth index lines) "*** Begin Patch")
      (error "apply_patch verification failed: missing *** Begin Patch"))
    (setq index (1+ index))
    (while (< index (length lines))
      (let ((line (nth index lines)))
        (cond
         ((equal line "*** End Patch")
          (setq index (length lines)))
         ((string-prefix-p "*** Add File: " line)
          (let ((path (string-remove-prefix "*** Add File: " line))
                file-lines
                ends-with-newline)
            (setq index (1+ index))
            (setq ends-with-newline t)
            (while (and (< index (length lines))
                        (not (string-prefix-p "*** " (nth index lines)))
                        (not (chat-files--no-newline-marker-p (nth index lines))))
              (let ((payload (nth index lines)))
                (unless (string-prefix-p "+" payload)
                  (error "apply_patch verification failed: invalid add line"))
                (push (substring payload 1) file-lines))
              (setq index (1+ index)))
            (when (and (< index (length lines))
                       (chat-files--no-newline-marker-p (nth index lines)))
              (setq ends-with-newline nil)
              (setq index (1+ index)))
            (push (list :type 'add
                        :path path
                        :content (string-join (nreverse file-lines) "\n")
                        :ends-with-newline ends-with-newline)
                  operations)))
         ((string-prefix-p "*** Delete File: " line)
          (push (list :type 'delete
                      :path (string-remove-prefix "*** Delete File: " line))
                operations)
          (setq index (1+ index)))
         ((string-prefix-p "*** Update File: " line)
          (let ((path (string-remove-prefix "*** Update File: " line))
                move-to
                hunks
                ends-with-newline-specified
                ends-with-newline)
            (setq index (1+ index))
            (when (and (< index (length lines))
                       (string-prefix-p "*** Move to: " (nth index lines)))
              (setq move-to (string-remove-prefix "*** Move to: " (nth index lines)))
              (setq index (1+ index)))
            (while (and (< index (length lines))
                        (string-prefix-p "@@" (nth index lines)))
              (let ((header (nth index lines))
                    hunk-lines)
                (setq index (1+ index))
                (while (and (< index (length lines))
                            (not (string-prefix-p "@@" (nth index lines)))
                            (not (string-prefix-p "*** " (nth index lines)))
                            (not (chat-files--no-newline-marker-p (nth index lines))))
                  (push (nth index lines) hunk-lines)
                  (setq index (1+ index)))
                (when (and (< index (length lines))
                           (chat-files--no-newline-marker-p (nth index lines)))
                  (setq ends-with-newline-specified t)
                  (setq ends-with-newline nil)
                  (setq index (1+ index)))
                (push (list :header header
                            :header-data (chat-files--parse-hunk-header header)
                            :lines (nreverse hunk-lines))
                      hunks)))
            (push (list :type 'update
                        :path path
                        :move-to move-to
                        :ends-with-newline-specified ends-with-newline-specified
                        :ends-with-newline ends-with-newline
                        :hunks (nreverse hunks))
                  operations)))
         ((string-empty-p line)
          (setq index (1+ index)))
         (t
          (error "apply_patch verification failed: unexpected line %S" line)))))
    (nreverse operations)))

(defun chat-files--diff-strings (path original-content new-content)
  "Return a unified diff for PATH from ORIGINAL-CONTENT to NEW-CONTENT."
  (let ((old-file (make-temp-file "chat-old-"))
        (new-file (make-temp-file "chat-new-")))
    (unwind-protect
        (progn
          (with-temp-file old-file
            (insert (or original-content "")))
          (with-temp-file new-file
            (insert (or new-content "")))
          (let* ((default-directory (file-name-as-directory
                                     (or (file-name-directory old-file)
                                         temporary-file-directory)))
                 (raw-diff (with-temp-buffer
                             (call-process "diff" nil t nil "-u" old-file new-file)
                             (buffer-string)))
                 (lines (split-string raw-diff "\n"))
                 (old-label (if (null original-content) "/dev/null" path))
                 (new-label (if (null new-content) "/dev/null" path)))
            (cond
             ((string-empty-p raw-diff)
              "")
             ((>= (length lines) 2)
              (string-join
               (append (list (format "--- %s" old-label)
                             (format "+++ %s" new-label))
                       (nthcdr 2 lines))
               "\n"))
             (t
              raw-diff))))
      (delete-file old-file)
      (delete-file new-file))))

(defun chat-files--apply-update-operation (content operation)
  "Apply update OPERATION to CONTENT."
  (let* ((state (chat-files--split-content-lines content))
         (lines (plist-get state :lines))
         (line-delta 0))
    (dolist (hunk (plist-get operation :hunks))
      (let* ((header-data (plist-get hunk :header-data))
             (old-count (and header-data (plist-get header-data :old-count)))
             (preferred-start (and header-data
                                   (+ (if (= old-count 0)
                                          (plist-get header-data :old-start)
                                        (1- (plist-get header-data :old-start)))
                                      line-delta))))
        (setq lines
              (chat-files--apply-hunk-to-lines-at-position
               lines
               (plist-get hunk :lines)
               preferred-start))
        (when header-data
          (setq line-delta
                (+ line-delta
                   (- (plist-get header-data :new-count)
                      (plist-get header-data :old-count)))))))
    (chat-files--join-content-lines
     (list :lines lines
           :ends-with-newline (if (plist-get operation :ends-with-newline-specified)
                                  (plist-get operation :ends-with-newline)
                                (plist-get state :ends-with-newline))))))

(defun chat-files--commit-apply-patch-operation (operation)
  "Execute parsed apply_patch OPERATION."
  (pcase (plist-get operation :type)
    ('add
     (let* ((target-path (chat-files--safe-path-p
                          (expand-file-name (plist-get operation :path) default-directory)))
            (content (chat-files--patch-operation-content operation)))
       (when (file-exists-p target-path)
         (error "apply_patch verification failed: file already exists: %s" target-path))
       (make-directory (file-name-directory target-path) t)
       (with-temp-file target-path
         (insert content))
       (list :path target-path
             :operation 'add
             :diff (chat-files--diff-strings target-path nil content))))
    ('delete
     (let* ((target-path (chat-files--safe-path-p
                          (expand-file-name (plist-get operation :path) default-directory)))
            (original-content (with-temp-buffer
                                (insert-file-contents target-path)
                                (buffer-string))))
       (delete-file target-path)
       (list :path target-path
             :operation 'delete
             :diff (chat-files--diff-strings target-path original-content nil))))
    ('update
     (let* ((source-path (chat-files--safe-path-p
                          (expand-file-name (plist-get operation :path) default-directory)))
            (original-content (with-temp-buffer
                                (insert-file-contents source-path)
                                (buffer-string)))
            (updated-content (chat-files--apply-update-operation original-content operation))
            (target-path (if-let ((move-to (plist-get operation :move-to)))
                             (chat-files--safe-path-p
                              (expand-file-name move-to default-directory))
                           source-path)))
       (when (and (not (equal target-path source-path))
                  (file-exists-p target-path))
         (error "apply_patch verification failed: move target exists: %s" target-path))
       (unless (equal target-path source-path)
         (delete-file source-path))
       (make-directory (file-name-directory target-path) t)
       (with-temp-file target-path
         (insert updated-content))
       (list :path target-path
             :operation (if (equal target-path source-path) 'update 'move)
             :diff (chat-files--diff-strings target-path original-content updated-content))))
    (_
     (error "apply_patch verification failed: unsupported operation"))))

(defun chat-files--planned-file-state (path states)
  "Return the planned file state for PATH from STATES."
  (or (gethash path states)
      (let ((state (if (file-exists-p path)
                       (list :exists t
                             :content (with-temp-buffer
                                        (insert-file-contents path)
                                        (buffer-string)))
                     (list :exists nil :content nil))))
        (puthash path state states)
        state)))

(defun chat-files--planned-file-exists-p (path states)
  "Return non-nil when PATH exists in the planned STATES."
  (plist-get (chat-files--planned-file-state path states) :exists))

(defun chat-files--planned-file-content (path states)
  "Return the planned file content for PATH from STATES."
  (plist-get (chat-files--planned-file-state path states) :content))

(defun chat-files--planned-set-file-state (path exists content states)
  "Store planned EXISTS and CONTENT for PATH in STATES."
  (puthash path (list :exists exists :content content) states))

(defun chat-files--plan-apply-patch-operation (operation states)
  "Plan parsed apply_patch OPERATION against STATES."
  (pcase (plist-get operation :type)
    ('add
     (let* ((target-path (chat-files--safe-path-p
                          (expand-file-name (plist-get operation :path) default-directory)))
            (content (chat-files--patch-operation-content operation)))
       (when (chat-files--planned-file-exists-p target-path states)
         (error "apply_patch verification failed: file already exists: %s" target-path))
       (chat-files--planned-set-file-state target-path t content states)
       (list :path target-path
             :operation 'add
             :diff (chat-files--diff-strings target-path nil content))))
    ('delete
     (let* ((target-path (chat-files--safe-path-p
                          (expand-file-name (plist-get operation :path) default-directory)))
            (original-content (chat-files--planned-file-content target-path states)))
       (unless (chat-files--planned-file-exists-p target-path states)
         (error "apply_patch verification failed: file does not exist: %s" target-path))
       (chat-files--planned-set-file-state target-path nil nil states)
       (list :path target-path
             :operation 'delete
             :diff (chat-files--diff-strings target-path original-content nil))))
    ('update
     (let* ((source-path (chat-files--safe-path-p
                          (expand-file-name (plist-get operation :path) default-directory)))
            (source-content (chat-files--planned-file-content source-path states))
            (target-path (if-let ((move-to (plist-get operation :move-to)))
                             (chat-files--safe-path-p
                              (expand-file-name move-to default-directory))
                           source-path)))
       (unless (chat-files--planned-file-exists-p source-path states)
         (error "apply_patch verification failed: file does not exist: %s" source-path))
       (let ((updated-content (chat-files--apply-update-operation source-content operation)))
         (when (and (not (equal target-path source-path))
                    (chat-files--planned-file-exists-p target-path states))
           (error "apply_patch verification failed: move target exists: %s" target-path))
         (unless (equal target-path source-path)
           (chat-files--planned-set-file-state source-path nil nil states))
         (chat-files--planned-set-file-state target-path t updated-content states)
         (list :path target-path
               :operation (if (equal target-path source-path) 'update 'move)
               :diff (chat-files--diff-strings target-path source-content updated-content)))))
    (_
     (error "apply_patch verification failed: unsupported operation"))))

(defun chat-files--commit-planned-file-states (states)
  "Commit planned file STATES to disk."
  (maphash
   (lambda (path state)
     (if (plist-get state :exists)
         (progn
           (make-directory (file-name-directory path) t)
           (with-temp-file path
             (insert (or (plist-get state :content) ""))))
       (when (file-exists-p path)
         (delete-file path))))
   states))

(defun chat-files-apply-patch (path-or-patch &optional patches)
  "Apply PATCHES to PATH-OR-PATCH or parse codex patch text."
  (if patches
      (chat-files-patch path-or-patch patches)
    (let* ((operations (chat-files--parse-apply-patch path-or-patch))
           (states (make-hash-table :test 'equal))
           results)
      (dolist (operation operations)
        (push (chat-files--plan-apply-patch-operation operation states) results))
      (chat-files--commit-planned-file-states states)
      (list :operations (nreverse results)
            :status 'success
            :diff (mapconcat (lambda (result)
                               (plist-get result :diff))
                             (nreverse results)
                             "\n")))))

(defun chat-files--normalize-patch (patch)
  "Normalize PATCH from plist or JSON alist into a plist."
  (cond
   ((and (listp patch) (keywordp (car patch)))
    patch)
   ((listp patch)
    (list :search (or (cdr (assoc 'search patch))
                      (cdr (assoc "search" patch)))
          :replace (or (cdr (assoc 'replace patch))
                       (cdr (assoc "replace" patch)))
          :line (or (cdr (assoc 'line patch))
                    (cdr (assoc "line" patch)))
          :all (or (cdr (assoc 'all patch))
                   (cdr (assoc "all" patch)))
          :count (or (cdr (assoc 'count patch))
                     (cdr (assoc "count" patch)))
          :regexp (or (cdr (assoc 'regexp patch))
                      (cdr (assoc "regexp" patch)))))
   (t
    (error "Invalid patch data: %S" patch))))

;; ------------------------------------------------------------------
;; File Concatenation and Assembly
;; ------------------------------------------------------------------

;;;###autoload
(defun chat-files-concat (output sources &optional separator)
  "Concatenate multiple files into OUTPUT.
SOURCES is a list of file paths.
SEPARATOR is an optional string to insert between files.

Returns a plist with :output, :sources, :total-size."
  (let ((safe-output (chat-files--safe-path-p output))
        (safe-sources (mapcar #'chat-files--safe-path-p sources))
        (total-size 0))
    (with-temp-buffer
      (dolist (source safe-sources)
        (insert-file-contents source)
        (when separator
          (insert separator))
        (cl-incf total-size (file-attribute-size
                             (file-attributes source))))
      (write-region (point-min) (point-max) safe-output))
    (list :output safe-output
          :sources safe-sources
          :total-size total-size
          :separator separator)))

;;;###autoload
(defun chat-files-split (path output-dir chunk-size &optional prefix)
  "Split file at PATH into chunks of CHUNK-SIZE lines.
Chunks are written to OUTPUT-DIR with optional PREFIX.

Returns a plist with :chunks (list of output paths), :lines-per-chunk."
  (let* ((safe-path (chat-files--safe-path-p path))
         (safe-dir (chat-files--safe-path-p output-dir))
         (prefix (or prefix "chunk-"))
         (chunk-num 0)
         (chunks '()))
    (unless (file-directory-p safe-dir)
      (make-directory safe-dir t))
    (with-temp-buffer
      (insert-file-contents safe-path)
      (goto-char (point-min))
      (while (not (eobp))
        (let ((chunk-path (expand-file-name
                          (format "%s%04d.txt" prefix chunk-num)
                          safe-dir)))
          (with-temp-file chunk-path
            (dotimes (_ chunk-size)
              (unless (eobp)
                (insert (buffer-substring (line-beginning-position)
                                         (1+ (line-end-position))))
                (forward-line 1))))
          (push chunk-path chunks)
          (cl-incf chunk-num))))
    (list :source safe-path
          :output-dir safe-dir
          :chunks (nreverse chunks)
          :chunk-count (length chunks)
          :lines-per-chunk chunk-size)))

;; ------------------------------------------------------------------
;; Summary and Statistics
;; ------------------------------------------------------------------

;;;###autoload
(defun chat-files-stat (path)
  "Get detailed statistics about file at PATH."
  (let* ((safe-path (chat-files--safe-path-p path))
         (attrs (file-attributes safe-path)))
    (with-temp-buffer
      (insert-file-contents safe-path)
      (let ((content (buffer-string)))
        (list :path safe-path
              :size (file-attribute-size attrs)
              :lines (count-lines (point-min) (point-max))
              :words (count-words (point-min) (point-max))
              :characters (length content)
              :mtime (file-attribute-modification-time attrs)
              :atime (file-attribute-access-time attrs)
              :mode (file-attribute-modes attrs)
              :is-directory (file-directory-p safe-path)
              :is-symlink (file-symlink-p safe-path))))))

;;;###autoload
(defun chat-files-summary (paths)
  "Generate a summary of multiple files.
Returns total size, line count, and file type distribution."
  (let ((total-size 0)
        (total-lines 0)
        (types (make-hash-table :test 'equal)))
    (dolist (path paths)
      (let* ((stat (chat-files-stat path))
             (ext (file-name-extension path)))
        (cl-incf total-size (plist-get stat :size))
        (cl-incf total-lines (plist-get stat :lines))
        (puthash (or ext "none")
                 (1+ (gethash (or ext "none") types 0))
                 types)))
    (list :files (length paths)
          :total-size total-size
          :total-lines total-lines
          :type-distribution (chat-files--hash-to-plist types))))

(defun chat-files--hash-to-plist (hash)
  "Convert hash table to plist."
  (let (result)
    (maphash (lambda (k v) (setq result (cons k (cons v result)))) hash)
    result))

;; ------------------------------------------------------------------
;; Built In Tool Registration
;; ------------------------------------------------------------------

(defun chat-files--register-built-in-tool (id name description parameters function)
  "Register one built in file tool."
  (chat-tool-forge-register
   (make-chat-forged-tool
    :id id
    :name name
    :description description
    :language 'elisp
    :parameters parameters
    :compiled-function function
    :is-active t
    :usage-count 0
    :version "1.0.0")))

(defun chat-files-open-file (path &optional line column)
  "Open PATH in Emacs and optionally move to LINE and COLUMN."
  (let* ((safe-path (chat-files--safe-path-p path))
         (buffer (find-file-noselect safe-path))
         actual-line
         actual-column)
    (with-current-buffer buffer
      (goto-char (point-min))
      (when (and line (integerp line) (> line 0))
        (forward-line (1- line)))
      (when (and column (integerp column) (> column 0))
        (move-to-column (1- column)))
      (setq actual-line (line-number-at-pos))
      (setq actual-column (1+ (current-column))))
    (pop-to-buffer buffer)
    (list :status "opened"
          :path safe-path
          :line actual-line
          :column actual-column)))

(defun chat-files-register-built-in-tools ()
  "Register the core file tools used by tool calling."
  (chat-files--register-built-in-tool
   'files_read
   "Read File"
   "Read content from a file"
   '((:name "path" :type "string" :required t)
     (:name "offset" :type "integer")
     (:name "limit" :type "integer"))
   (lambda (path &optional offset limit)
     (chat-files-read path offset limit)))
  (chat-files--register-built-in-tool
   'files_read_lines
   "Read File Lines"
   "Read a line range from a file"
   '((:name "path" :type "string" :required t)
     (:name "start_line" :type "integer")
     (:name "num_lines" :type "integer"))
   (lambda (path &optional start-line num-lines)
     (chat-files-read-lines path start-line num-lines)))
  (chat-files--register-built-in-tool
   'open_file
   "Open File"
   "Open a file in Emacs and optionally jump to a line and column"
   '((:name "path" :type "string" :required t)
     (:name "line" :type "integer")
     (:name "column" :type "integer"))
   (lambda (path &optional line column)
     (chat-files-open-file path line column)))
  (chat-files--register-built-in-tool
   'files_list
   "List Files"
   "List files in a directory"
   '((:name "directory" :type "string" :required t)
     (:name "pattern" :type "string")
     (:name "recursive" :type "boolean"))
   (lambda (directory &optional pattern recursive)
     (chat-files-list directory pattern recursive)))
  (chat-files--register-built-in-tool
   'files_grep
   "Search File"
   "Search for a pattern inside one known file"
   '((:name "pattern" :type "string" :required t)
     (:name "path" :type "string" :required t)
     (:name "context_lines" :type "integer"))
   (lambda (pattern path &optional context-lines)
     (chat-files-grep pattern path context-lines)))
  (chat-files--register-built-in-tool
   'files_find
   "Find In Directory"
   "Recursively find files containing a pattern in a directory"
   '((:name "directory" :type "string" :required t)
     (:name "pattern" :type "string" :required t)
     (:name "file_pattern" :type "string"))
   (lambda (directory pattern &optional file-pattern)
     (chat-files-find directory pattern file-pattern)))
  (chat-files--register-built-in-tool
   'files_write
   "Write File"
   "Write content to a file"
   '((:name "path" :type "string" :required t)
     (:name "content" :type "string" :required t)
     (:name "append" :type "boolean"))
   (lambda (path content &optional append)
     (chat-files-write path content append)))
  (chat-files--register-built-in-tool
   'files_replace
   "Replace File Text"
   "Replace exact text or regex matches inside a file"
   '((:name "path" :type "string" :required t)
     (:name "search" :type "string" :required t)
     (:name "replace" :type "string" :required t)
     (:name "all" :type "boolean")
     (:name "expected_count" :type "integer")
     (:name "regexp" :type "boolean")
     (:name "line_hint" :type "integer"))
   (lambda (path search replace &optional all expected-count regexp line-hint)
     (chat-files-replace path search replace all expected-count regexp line-hint)))
  (chat-files--register-built-in-tool
   'files_patch
   "Patch File"
   "Apply legacy atomic search and replace patches to a file"
   '((:name "path" :type "string" :required t)
     (:name "patches" :type "array" :required t))
   (lambda (path patches)
     (chat-files-patch path patches)))
  (chat-files--register-built-in-tool
   'apply_patch
   "Apply Patch"
   "Apply codex-style patch text for targeted file edits"
   '((:name "patch" :type "string" :required t))
   (lambda (patch)
     (chat-files-apply-patch patch))))

;; ------------------------------------------------------------------
;; Tool Interface for AI
;; ------------------------------------------------------------------

;;;###autoload
(defun chat-files-as-tool-spec ()
  "Return the file operations tool specification for LLM.
This describes available file operations to the AI."
  (list
   (list :name "files_read"
         :description "Read content of a file"
         :parameters '((:name "path" :type "string" :required t)
                       (:name "offset" :type "integer")
                       (:name "limit" :type "integer")))
   (list :name "files_read_lines"
         :description "Read specific line range from a file"
         :parameters '((:name "path" :type "string" :required t)
                       (:name "start_line" :type "integer")
                       (:name "num_lines" :type "integer")))
   (list :name "open_file"
         :description "Open a file in Emacs and optionally jump to a line and column"
         :parameters '((:name "path" :type "string" :required t)
                       (:name "line" :type "integer")
                       (:name "column" :type "integer")))
   (list :name "files_grep"
         :description "Search for pattern in a file"
         :parameters '((:name "pattern" :type "string" :required t)
                       (:name "path" :type "string" :required t)
                       (:name "context_lines" :type "integer")))
   (list :name "files_find"
         :description "Find files containing pattern"
         :parameters '((:name "directory" :type "string" :required t)
                       (:name "pattern" :type "string" :required t)
                       (:name "file_pattern" :type "string")))
   (list :name "files_list"
         :description "List files in a directory"
         :parameters '((:name "directory" :type "string" :required t)
                       (:name "pattern" :type "string")
                       (:name "recursive" :type "boolean")))
   (list :name "files_write"
         :description "Write content to a file"
         :parameters '((:name "path" :type "string" :required t)
                       (:name "content" :type "string" :required t)
                       (:name "append" :type "boolean")))
   (list :name "files_replace"
         :description "Replace exact text or regex matches in a file"
         :parameters '((:name "path" :type "string" :required t)
                       (:name "search" :type "string" :required t)
                       (:name "replace" :type "string" :required t)
                       (:name "all" :type "boolean")
                       (:name "expected_count" :type "integer")
                       (:name "regexp" :type "boolean")
                       (:name "line_hint" :type "integer")))
   (list :name "files_patch"
         :description "Apply multiple legacy search/replace patches atomically"
         :parameters '((:name "path" :type "string" :required t)
                       (:name "patches" :type "array" :required t)))
   (list :name "apply_patch"
         :description "Apply codex-style patch text to one or more files"
         :parameters '((:name "patch" :type "string" :required t)))))

;; ------------------------------------------------------------------
;; Additional Operations (Extended)
;; ------------------------------------------------------------------

;;;###autoload
(defun chat-files-diff (path1 path2 &optional context)
  "Compare two files and return differences.
CONTEXT specifies number of context lines (default 3).
Returns unified diff format as string."
  (let* ((safe-path1 (chat-files--safe-path-p path1))
         (safe-path2 (chat-files--safe-path-p path2))
         (ctx (or context 3)))
    (with-temp-buffer
      (let ((exit-code (call-process
                        "diff"
                        nil
                        t
                        nil
                        (format "-u%d" ctx)
                        safe-path1
                        safe-path2)))
        (cond
         ((or (eq exit-code 0)
              (eq exit-code 1))
          (buffer-string))
         (t
          (error "Diff failed for %s and %s" safe-path1 safe-path2)))))))

;;;###autoload
(defun chat-files-checksum (path &optional algorithm)
  "Calculate checksum of file at PATH.
ALGORITHM can be 'md5, 'sha1, 'sha256 (default 'sha256).
Returns plist with :hash, :algorithm, :path."
  (let* ((safe-path (chat-files--safe-path-p path))
         (algo (or algorithm 'sha256))
         hash)
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally safe-path)
      (setq hash (secure-hash algo (current-buffer))))
    (list :hash hash
          :algorithm algo
          :path safe-path
          :short-hash (substring hash 0 16))))

;;;###autoload
(defun chat-files-encode (path target-encoding &optional output-path)
  "Convert file encoding.
TARGET-ENCODING is the desired encoding (e.g., 'utf-8, 'gbk).
If OUTPUT-PATH is nil, overwrite original file."
  (let* ((safe-path (chat-files--safe-path-p path))
         (output (or output-path safe-path)))
    (with-temp-buffer
      (let ((coding-system-for-read 'undecided))
        (insert-file-contents safe-path))
      (let ((coding-system-for-write target-encoding))
        (write-region (point-min) (point-max) output)))
    (list :source safe-path
          :output output
          :encoding target-encoding)))

;;;###autoload
(defun chat-files-backup (path &optional backup-dir)
  "Create a backup of file at PATH.
BACKUP-DIR defaults to same directory with .bak extension."
  (let* ((safe-path (chat-files--safe-path-p path))
         (backup (or backup-dir
                    (concat safe-path ".bak." 
                            (format-time-string "%Y%m%d%H%M%S")))))
    (copy-file safe-path backup t)
    (list :original safe-path
          :backup backup
          :size (file-attribute-size (file-attributes safe-path)))))

;;;###autoload
(defun chat-files-restore (backup-path target-path)
  "Restore file from BACKUP-PATH to TARGET-PATH."
  (let ((safe-backup (chat-files--safe-path-p backup-path))
        (safe-target (chat-files--safe-path-p target-path)))
    (copy-file safe-backup safe-target t)
    (list :restored-from safe-backup
          :target safe-target
          :status 'success)))

;;;###autoload
(defun chat-files-batch-rename (directory pattern replacement &optional dry-run)
  "Batch rename files in DIRECTORY matching PATTERN to REPLACEMENT.
If DRY-RUN is non-nil, only show what would be done without executing.
PATTERN is a regex, REPLACEMENT can use \1, \2 etc for capture groups."
  (let* ((safe-dir (chat-files--safe-path-p directory))
         (files (directory-files safe-dir nil pattern))
         (operations '()))
    (dolist (file files)
      (let* ((old-path (expand-file-name file safe-dir))
             (new-name (replace-regexp-in-string pattern replacement file))
             (new-path (expand-file-name new-name safe-dir)))
        (unless (string= old-path new-path)
          (push (list :from old-path :to new-path) operations))))
    (unless dry-run
      (dolist (op operations)
        (rename-file (plist-get op :from) (plist-get op :to) t)))
    (list :directory safe-dir
          :pattern pattern
          :replacement replacement
          :dry-run dry-run
          :operations (nreverse operations)
          :count (length operations))))

;;;###autoload
(defun chat-files-touch (path)
  "Create empty file or update timestamp of existing file at PATH."
  (let ((safe-path (chat-files--safe-path-p path)))
    (if (file-exists-p safe-path)
        (set-file-times safe-path)
      (with-temp-file safe-path))
    (list :path safe-path
          :existed (file-exists-p safe-path)
          :mtime (file-attribute-modification-time
                  (file-attributes safe-path)))))

;;;###autoload
(defun chat-files-symlink (target link-path &optional symbolic)
  "Create a link at LINK-PATH pointing to TARGET.
If SYMBOLIC is nil, creates hard link; if t, creates symbolic link."
  (let ((safe-target (chat-files--safe-path-p target))
        (safe-link (chat-files--safe-path-p link-path)))
    (if symbolic
        (make-symbolic-link safe-target safe-link t)
      (add-name-to-file safe-target safe-link t))
    (list :target safe-target
          :link safe-link
          :type (if symbolic 'symbolic 'hard))))

;;;###autoload
(defun chat-files-truncate (path max-lines &optional keep-end)
  "Truncate file to MAX-LINES.
If KEEP-END is non-nil, keep the end of file; otherwise keep the beginning."
  (let* ((safe-path (chat-files--safe-path-p path))
         (backup (chat-files-backup safe-path)))
    (condition-case err
        (with-temp-buffer
          (insert-file-contents safe-path)
          (let ((total-lines (count-lines (point-min) (point-max))))
            (when (> total-lines max-lines)
              (if keep-end
                  (progn
                    (goto-char (point-max))
                    (forward-line (- max-lines total-lines))
                    (delete-region (point-min) (point)))
                (goto-char (point-min))
                (forward-line max-lines)
                (delete-region (point) (point-max))))
            (write-region (point-min) (point-max) safe-path)
            (list :path safe-path
                  :original-lines total-lines
                  :kept-lines (min total-lines max-lines)
                  :keep-end keep-end
                  :backup (plist-get backup :backup))))
      (error
       (chat-files-restore (plist-get backup :backup) safe-path)
       (error "Truncate failed, restored from backup: %s" 
              (error-message-string err))))))

;;;###autoload
(defun chat-files-rotate (path &optional max-backups)
  "Rotate log files, keeping MAX-BACKUPS versions.
Default is 5 backups: file -> file.1 -> file.2 -> ..."
  (let* ((safe-path (chat-files--safe-path-p path))
         (max (or max-backups 5)))
    ;; Delete oldest backup
    (let ((oldest (format "%s.%d" safe-path max)))
      (when (file-exists-p oldest)
        (delete-file oldest)))
    ;; Shift backups
    (cl-loop for i from (1- max) downto 1 do
             (let ((old (format "%s.%d" safe-path i))
                   (new (format "%s.%d" safe-path (1+ i))))
               (when (file-exists-p old)
                 (rename-file old new t))))
    ;; Move current to .1
    (when (file-exists-p safe-path)
      (rename-file safe-path (format "%s.1" safe-path) t))
    ;; Create new empty file
    (chat-files-touch safe-path)
    (list :path safe-path
          :max-backups max
          :status 'rotated)))

;;;###autoload
(defun chat-files-format (path &optional format-type)
  "Auto-format file content based on file type or FORMAT-TYPE.
Supports: 'json, 'xml, 'elisp, 'python, etc."
  (let* ((safe-path (chat-files--safe-path-p path))
         (type (or format-type
                   (pcase (file-name-extension path)
                     ("json" 'json)
                     ("xml" 'xml)
                     ("el" 'elisp)
                     ("py" 'python)
                     (_ nil)))))
    (with-temp-buffer
      (insert-file-contents safe-path)
      (pcase type
        ('json
         (json-pretty-print-buffer))
        ('xml
         (xml-mode)
         (indent-region (point-min) (point-max)))
        ('elisp
         (emacs-lisp-mode)
         (indent-region (point-min) (point-max)))
        (_
         (error "Unknown format type: %s" type)))
      (write-region (point-min) (point-max) safe-path))
    (list :path safe-path
          :format type
          :status 'formatted)))

;;;###autoload
(defun chat-files-archive (output-archive sources &optional format)
  "Create archive from SOURCES.
FORMAT can be 'tar, 'zip (default 'tar).
OUTPUT-ARCHIVE is the resulting archive path."
  (let* ((safe-output (chat-files--safe-path-p output-archive))
         (safe-sources (mapcar #'chat-files--safe-path-p sources))
         (fmt (or format 'tar)))
    (pcase fmt
      ('tar
       (apply #'call-process "tar" nil nil nil
              "-cf" safe-output
              (mapcar (lambda (s) (file-relative-name s default-directory))
                      safe-sources)))
      ('zip
       (apply #'call-process "zip" nil nil nil
              "-r" safe-output
              (mapcar (lambda (s) (file-relative-name s default-directory))
                      safe-sources))))
    (list :archive safe-output
          :format fmt
          :sources safe-sources
          :size (file-attribute-size (file-attributes safe-output)))))

;;;###autoload
(defun chat-files-with-temp (fn &rest args)
  "Execute FN with a temporary file, clean up afterwards.
Returns the result of FN, which receives temp path as first argument."
  (let ((temp (make-temp-file "chat-files-")))
    (unwind-protect
        (apply fn temp args)
      (when (file-exists-p temp)
        (delete-file temp)))))

;;;###autoload
(defun chat-files-preview (path &optional max-lines)
  "Generate a preview of file suitable for AI context.
Includes file header, structure outline, and sample content."
  (let* ((safe-path (chat-files--safe-path-p path))
         (max (or max-lines 50))
         (stat (chat-files-stat safe-path)))
    (with-temp-buffer
      (insert-file-contents safe-path)
      (let* ((lines (split-string (buffer-string) "\n" t))
             (total (length lines))
             (head (seq-take lines (min 20 max)))
             (tail (when (> total max)
                     (seq-take (reverse lines) 10)))
             (outline (chat-files--extract-outline safe-path)))
        (list :path safe-path
              :size (plist-get stat :size)
              :total-lines total
              :preview-lines (min max total)
              :head head
              :tail (reverse tail)
              :outline outline
              :file-type (file-name-extension safe-path))))))

(defun chat-files--extract-outline (path)
  "Extract structural outline from file (functions, classes, sections)."
  (with-temp-buffer
    (insert-file-contents path)
    (let ((ext (file-name-extension path))
          (outline '()))
      (cond
       ;; Emacs Lisp
       ((string= ext "el")
        (goto-char (point-min))
        (while (re-search-forward "^(def\\(un\\|macro\\|var\\|custom\\|class\\)\\s-+(\\([^ )]+\\)" nil t)
          (push (list :type (match-string 1)
                     :name (match-string 2)
                     :line (line-number-at-pos))
                outline)))
       ;; Python
       ((string= ext "py")
        (goto-char (point-min))
        (while (re-search-forward "^\\(def\\|class\\)\\s-+(\\([^(:]+\\)" nil t)
          (push (list :type (match-string 1)
                     :name (match-string 2)
                     :line (line-number-at-pos))
                outline)))
       ;; Markdown / Org
       ((member ext '("md" "org"))
        (goto-char (point-min))
        (while (re-search-forward "^\\(#+\\|\\*+\\)\\s-+\\(.+\\)$" nil t)
          (push (list :type 'heading
                     :level (length (match-string 1))
                     :title (match-string 2)
                     :line (line-number-at-pos))
                outline))))
      (nreverse outline))))

(provide 'chat-files)
;;; chat-files.el ends here
