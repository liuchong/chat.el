;;; chat-files.el --- File operations for AI agent -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

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
(require 'seq)
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
  '("~/" "/tmp/" "/var/tmp/")
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

(defun chat-files--safe-path-p (path)
  "Check if PATH is safe to access.
Returns nil if path matches deny patterns or is outside allowed directories."
  (let ((expanded (expand-file-name path)))
    ;; Check deny patterns
    (when (seq-find (lambda (pat)
                      (string-match-p pat expanded))
                    chat-files-deny-patterns)
      (error "Access denied: path matches sensitive file pattern"))
    ;; Check allowed directories
    (unless (seq-find (lambda (dir)
                        (string-prefix-p (expand-file-name dir) expanded))
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
         (start (or start-line 1)))
    (with-temp-buffer
      (insert-file-contents safe-path)
      (let* ((total (count-lines (point-min) (point-max)))
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
         (files '()))
    (if recursive
        (directory-files-recursively safe-dir pattern)
      (progn
        (dolist (name (directory-files safe-dir nil pattern))
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
    (with-temp-buffer
      (when append
        (insert-file-contents safe-path))
      (goto-char (point-max))
      (insert content)
      (let ((coding-system-for-write coding-system))
        (write-region (point-min) (point-max) safe-path)))
    (list :path safe-path
          :operation (if append 'append 'write)
          :bytes-written (length content)
          :encoding coding-system)))

;;;###autoload
(defun chat-files-replace (path search replace &optional limit)
  "Replace SEARCH pattern with REPLACE text in file at PATH.
If LIMIT is specified, only perform up to LIMIT replacements.
SEARCH can be a string or regex (if it contains special chars).

Returns a plist with :replacements-made, :path."
  (let* ((safe-path (chat-files--safe-path-p path))
         (count 0))
    (with-temp-buffer
      (insert-file-contents safe-path)
      (goto-char (point-min))
      (let ((case-fold-search nil))
        (while (and (or (null limit) (< count limit))
                    (search-forward search nil t))
          (replace-match replace t t)
          (cl-incf count)))
      (write-region (point-min) (point-max) safe-path))
    (list :path safe-path
          :replacements-made count
          :search search
          :replace replace)))

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
  :count - optional max replacements for this patch

All patches are applied atomically (or none if any fails)."
  (let* ((safe-path (chat-files--safe-path-p path))
         (backup-path (concat safe-path ".chat-backup")))
    ;; Create backup
    (copy-file safe-path backup-path t)
    (condition-case err
        (with-temp-buffer
          (insert-file-contents safe-path)
          (dolist (patch patches)
            (let ((search (plist-get patch :search))
                  (replace (plist-get patch :replace))
                  (line (plist-get patch :line))
                  (count (or (plist-get patch :count) 1)))
              (if line
                  (progn
                    (goto-char (point-min))
                    (forward-line (1- line))
                    (search-forward search (line-end-position) t)
                    (replace-match replace t t))
                (goto-char (point-min))
                (dotimes (_ count)
                  (when (search-forward search nil t)
                    (replace-match replace t t))))))
          (write-region (point-min) (point-max) safe-path)
          (delete-file backup-path)
          (list :path safe-path
                :patches-applied (length patches)
                :status 'success))
      (error
       ;; Restore from backup
       (rename-file backup-path safe-path t)
       (error "Patch failed: %s" (error-message-string err))))))

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
   "Search for a pattern inside a file"
   '((:name "pattern" :type "string" :required t)
     (:name "path" :type "string" :required t)
     (:name "context_lines" :type "integer"))
   (lambda (pattern path &optional context-lines)
     (chat-files-grep pattern path context-lines)))
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
   "Replace text inside a file"
   '((:name "path" :type "string" :required t)
     (:name "search" :type "string" :required t)
     (:name "replace" :type "string" :required t)
     (:name "limit" :type "integer"))
   (lambda (path search replace &optional limit)
     (chat-files-replace path search replace limit)))
  (chat-files--register-built-in-tool
   'files_patch
   "Patch File"
   "Apply atomic search and replace patches to a file"
   '((:name "path" :type "string" :required t)
     (:name "patches" :type "array" :required t))
   (lambda (path patches)
     (chat-files-patch path patches))))

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
         :description "Replace text in a file"
         :parameters '((:name "path" :type "string" :required t)
                       (:name "search" :type "string" :required t)
                       (:name "replace" :type "string" :required t)))
   (list :name "files_patch"
         :description "Apply multiple patches atomically"
         :parameters '((:name "path" :type "string" :required t)
                       (:name "patches" :type "array" :required t)))
   (list :name "files_move"
         :description "Move or rename a file"
         :parameters '((:name "source" :type "string" :required t)
                       (:name "dest" :type "string" :required t)))
   (list :name "files_stat"
         :description "Get file statistics"
         :parameters '((:name "path" :type "string" :required t)))))

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
      (let ((diff-switches (format "-u%d" ctx)))
        (diff safe-path1 safe-path2 nil 'noasync)
        (buffer-string)))))

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
