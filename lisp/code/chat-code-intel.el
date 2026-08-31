;;; chat-code-intel.el --- Code intelligence for chat.el -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;;; Commentary:

;; This module provides code intelligence features for chat.el.
;; Features:
;; - Symbol indexing with cross-references
;; - Call graph analysis
;; - Reference tracking
;; - Import/dependency analysis

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)

;; ------------------------------------------------------------------
;; Customization
;; ------------------------------------------------------------------

(defgroup chat-code-intel nil
  "Code intelligence for chat.el."
  :group 'chat-code
  :prefix "chat-code-intel-")

(defcustom chat-code-intel-index-directory
  (expand-file-name "~/.chat/index/")
  "Directory for code indexes."
  :type 'directory)

(defcustom chat-code-intel-max-file-size (* 500 1024)
  "Maximum file size to index in bytes."
  :type 'integer)

;; ------------------------------------------------------------------
;; Data Structures
;; ------------------------------------------------------------------

(cl-defstruct chat-code-symbol
  name type file line column signature docstring)

(cl-defstruct chat-code-reference
  symbol-name file line column type)

(cl-defstruct chat-code-index
  project-root symbols files references call-graph)

;; ------------------------------------------------------------------
;; Index Management
;; ------------------------------------------------------------------

(defvar chat-code-intel--active-indexes (make-hash-table :test 'equal))

(defun chat-code-intel-active-index (project-root)
  "Return the in-memory index for PROJECT-ROOT without disk access."
  (gethash project-root chat-code-intel--active-indexes))

(defun chat-code-intel-get-index (project-root)
  "Get or create index for PROJECT-ROOT."
  (or (gethash project-root chat-code-intel--active-indexes)
      (chat-code-intel-load-index project-root)))

;;;###autoload
(defun chat-code-intel-index-project (project-root)
  "Index all files in PROJECT-ROOT with cross-references."
  (interactive "DProject root: ")
  (message "Indexing project: %s..." project-root)
  (let ((index (make-chat-code-index
                :project-root project-root
                :symbols (make-hash-table :test 'equal)
                :files nil
                :references (make-hash-table :test 'equal)
                :call-graph (make-hash-table :test 'equal))))
    ;; Phase 1: Collect all symbols
    (message "  Phase 1: Collecting symbols...")
    (dolist (file (chat-code-intel--find-source-files project-root))
      (chat-code-intel--index-file-symbols index file))
    ;; Phase 2: Find references
    (message "  Phase 2: Finding references...")
    (dolist (file (chat-code-index-files index))
      (chat-code-intel--index-file-references index file))
    ;; Phase 3: Build call graph
    (message "  Phase 3: Building call graph...")
    (chat-code-intel--build-call-graph index)
    ;; Save and cache
    (chat-code-intel-save-index index)
    (puthash project-root index chat-code-intel--active-indexes)
    (message "Indexed %d files, %d symbols, %d references"
             (length (chat-code-index-files index))
             (hash-table-count (chat-code-index-symbols index))
             (hash-table-count (chat-code-index-references index)))
    index))

(defun chat-code-intel--find-source-files (project-root)
  "Find all source files in PROJECT-ROOT."
  (let (files)
    (when (file-directory-p project-root)
      (dolist (ext '("py" "js" "mjs" "cjs" "ts" "mts" "cts" "jsx" "tsx"
                     "el" "go" "rs" "zig" "clj" "cljc" "cljs" "rb"
                     "java" "c" "h" "cc" "cpp" "cxx" "hh" "hpp" "hxx"
                     "sql"))
        (setq files (append files
                           (directory-files-recursively
                            project-root
                            (format "\\.%s$" ext)
                            nil)))))
    files))

;; ------------------------------------------------------------------
;; Symbol Indexing
;; ------------------------------------------------------------------

(defun chat-code-intel--index-file-symbols (index file-path)
  "Index symbols from FILE-PATH."
  (when (and (file-exists-p file-path)
             (< (file-attribute-size (file-attributes file-path))
                chat-code-intel-max-file-size))
    (let ((symbols (chat-code-intel--extract-symbols file-path)))
      (dolist (sym symbols)
        (puthash (chat-code-symbol-name sym)
                 (cons sym (gethash (chat-code-symbol-name sym)
                                   (chat-code-index-symbols index)))
                 (chat-code-index-symbols index)))
      (push file-path (chat-code-index-files index)))))

(defun chat-code-intel--extract-symbols (file-path)
  "Extract symbols from FILE-PATH."
  (let ((language (chat-code-intel--detect-language file-path)))
    (with-temp-buffer
      (insert-file-contents file-path)
      (let ((symbols (chat-code-intel-extract-buffer-symbols language)))
        (dolist (sym symbols)
          (setf (chat-code-symbol-file sym) file-path))
        symbols))))

(defun chat-code-intel-extract-buffer-symbols (language)
  "Extract fallback symbols for LANGUAGE from the current buffer."
  (pcase language
    ('python (chat-code-intel--parse-python-symbols))
    ((or 'javascript 'typescript) (chat-code-intel--parse-js-symbols))
    ('emacs-lisp (chat-code-intel--parse-elisp-symbols))
    ('go (chat-code-intel--parse-go-symbols))
    ('rust (chat-code-intel--parse-rust-symbols))
    ('zig (chat-code-intel--parse-zig-symbols))
    ('clojure (chat-code-intel--parse-clojure-symbols))
    ('java (chat-code-intel--parse-java-symbols))
    ((or 'c 'cpp) (chat-code-intel--parse-c-family-symbols language))
    ('sql (chat-code-intel--parse-sql-symbols))
    (_ nil)))

(defun chat-code-intel-extract-symbols (file-path)
  "Return fallback structural symbols extracted from FILE-PATH.

This public wrapper lets cache builders reuse the lightweight parser
without depending on its implementation name."
  (chat-code-intel--extract-symbols file-path))

;; ------------------------------------------------------------------
;; Language Parsers
;; ------------------------------------------------------------------

(defun chat-code-intel--detect-language (file-path)
  "Detect language for FILE-PATH."
  (let ((ext (file-name-extension file-path)))
    (pcase ext
      ("py" 'python)
      ("js" 'javascript)
      ("ts" 'typescript)
      ("mts" 'typescript)
      ("cts" 'typescript)
      ("jsx" 'javascript)
      ("tsx" 'typescript)
      ("el" 'emacs-lisp)
      ("go" 'go)
      ("rs" 'rust)
      ("zig" 'zig)
      ((or "clj" "cljc" "cljs") 'clojure)
      ("rb" 'ruby)
      ("java" 'java)
      ((or "c" "h") 'c)
      ((or "cc" "cpp" "cxx" "hh" "hpp" "hxx") 'cpp)
      ("sql" 'sql)
      (_ 'unknown))))

(defun chat-code-intel-detect-language (file-path)
  "Return the fallback parser language for FILE-PATH."
  (chat-code-intel--detect-language file-path))

(defun chat-code-intel--parse-python-symbols ()
  "Parse Python symbols."
  (let (symbols)
    (goto-char (point-min))
    (while (re-search-forward
            "^\\s-*def\\s-+\\([[:alpha:]_][[:alnum:]_]*\\)" nil t)
      (push (make-chat-code-symbol
             :name (match-string 1)
             :type 'function
             :line (line-number-at-pos)
             :column nil
             :signature nil
             :docstring nil)
            symbols))
    (goto-char (point-min))
    (while (re-search-forward
            "^\\s-*class\\s-+\\([[:alpha:]_][[:alnum:]_]*\\)" nil t)
      (push (make-chat-code-symbol
             :name (match-string 1)
             :type 'class
             :line (line-number-at-pos)
             :column nil
             :signature nil
             :docstring nil)
            symbols))
    symbols))

(defun chat-code-intel--parse-js-symbols ()
  "Parse JavaScript symbols."
  (let (symbols)
    (goto-char (point-min))
    (while (re-search-forward
            "\\(?:function\\s-+\\|const\\s-+\\|let\\s-+\\|var\\s-+\\)\\([[:alpha:]_$][[:alnum:]_$]*\\)"
            nil t)
      (push (make-chat-code-symbol
             :name (match-string 1)
             :type 'function
             :line (line-number-at-pos)
             :column nil
             :signature nil
             :docstring nil)
            symbols))
    (goto-char (point-min))
    (while (re-search-forward
            "^[[:space:]]*\\(class\\|interface\\)\\s-+\\([^ {]+\\)" nil t)
      (push (make-chat-code-symbol
             :name (match-string 2)
             :type (if (string= (match-string 1) "interface") 'interface 'class)
             :line (line-number-at-pos)
             :column nil :signature nil :docstring nil)
            symbols))
    symbols))

(defun chat-code-intel--parse-elisp-symbols ()
  "Parse Emacs Lisp symbols."
  (let (symbols)
    (goto-char (point-min))
    (while (re-search-forward
            "(\\(defun\\|defmacro\\|cl-defun\\|cl-defgeneric\\|cl-defmethod\\)\\s-+\\([^[:space:]()]+\\)"
            nil t)
      (push (make-chat-code-symbol
             :name (match-string 2)
             :type (pcase (match-string 1)
                     ("cl-defgeneric" 'interface)
                     ("cl-defmethod" 'method)
                     ("defmacro" 'macro)
                     (_ 'function))
             :line (line-number-at-pos)
             :column nil
             :signature nil
             :docstring nil)
            symbols))
    symbols))

(defun chat-code-intel--parse-go-symbols ()
  "Parse Go symbols."
  (let (symbols)
    (goto-char (point-min))
    (while (re-search-forward
            "^[[:space:]]*func\\s-+\\(?:([^)]*)\\s-+\\)?\\([[:alpha:]_][[:alnum:]_]*\\)"
            nil t)
      (push (make-chat-code-symbol
             :name (match-string 1)
             :type 'function
             :line (line-number-at-pos)
             :column nil
             :signature nil
             :docstring nil)
            symbols))
    (goto-char (point-min))
    (while (re-search-forward
            "^[[:space:]]*type\\s-+\\([^[:space:]]+\\)\\s-+\\(interface\\|struct\\)" nil t)
      (push (make-chat-code-symbol
             :name (match-string 1)
             :type (if (string= (match-string 2) "interface") 'interface 'struct)
             :line (line-number-at-pos)
             :column nil :signature nil :docstring nil)
            symbols))
    symbols))

(defun chat-code-intel--parse-rust-symbols ()
  "Parse Rust symbols."
  (let (symbols)
    (goto-char (point-min))
    (while (re-search-forward
            "^\\s-*fn\\s-+\\([[:alpha:]_][[:alnum:]_]*\\)" nil t)
      (push (make-chat-code-symbol
             :name (match-string 1)
             :type 'function
             :line (line-number-at-pos)
             :column nil
             :signature nil
             :docstring nil)
            symbols))
    (goto-char (point-min))
    (while (re-search-forward
            "^[[:space:]]*\\(trait\\|struct\\|enum\\)\\s-+\\([[:alpha:]_][[:alnum:]_]*\\)" nil t)
      (push (make-chat-code-symbol
             :name (match-string 2)
             :type (pcase (match-string 1)
                     ("trait" 'interface)
                     ("enum" 'enum)
                     (_ 'struct))
             :line (line-number-at-pos)
             :column nil :signature nil :docstring nil)
            symbols))
    symbols))

(defun chat-code-intel--parse-zig-symbols ()
  "Parse Zig functions and named container declarations."
  (let (symbols)
    (goto-char (point-min))
    (while (re-search-forward
            "^[[:space:]]*\\(?:pub[[:space:]]+\\)?fn[[:space:]]+\\([[:alpha:]_][[:alnum:]_]*\\)"
            nil t)
      (push (make-chat-code-symbol
             :name (match-string 1) :type 'function
             :line (line-number-at-pos))
            symbols))
    (goto-char (point-min))
    (while (re-search-forward
            "^[[:space:]]*\\(?:pub[[:space:]]+\\)?const[[:space:]]+\\([[:alpha:]_][[:alnum:]_]*\\)[[:space:]]*=[[:space:]]*\\(struct\\|enum\\|union\\)"
            nil t)
      (push (make-chat-code-symbol
             :name (match-string 1)
             :type (if (string= (match-string 2) "enum") 'enum 'struct)
             :line (line-number-at-pos))
            symbols))
    symbols))

(defun chat-code-intel--parse-clojure-symbols ()
  "Parse common Clojure definitions without evaluating forms."
  (let (symbols)
    (goto-char (point-min))
    (while (re-search-forward
            "^[[:space:]]*(\\(defn\\|defmacro\\|def\\|defprotocol\\|defrecord\\|deftype\\)[[:space:]]+\\([[:alpha:]_*+!?<>/=.-][[:alnum:]_*+!?<>/=.-]*\\)"
            nil t)
      (push (make-chat-code-symbol
             :name (match-string 2)
             :type (pcase (match-string 1)
                     ("defmacro" 'macro)
                     ("defprotocol" 'interface)
                     ((or "defrecord" "deftype") 'struct)
                     ("def" 'variable)
                     (_ 'function))
             :line (line-number-at-pos))
            symbols))
    symbols))

(defun chat-code-intel--declaration-line-p ()
  "Return non-nil when the current C-family match begins like a declaration."
  (save-excursion
    (beginning-of-line)
    (not (looking-at-p
          "[[:space:]]*\\(?:return\\|throw\\|new\\|if\\|for\\|while\\|switch\\|catch\\|sizeof\\)\\_>"))))

(defun chat-code-intel--parse-c-like-functions ()
  "Parse C-shaped function declarations in the current buffer."
  (let (symbols)
    (goto-char (point-min))
    (while (re-search-forward
            "^[[:space:]]*\\(?:[[:alnum:]_$:<>,.*&?]+[[:space:]]+\\)+\\([[:alpha:]_$][[:alnum:]_$]*\\)[[:space:]]*("
            nil t)
      (when (chat-code-intel--declaration-line-p)
        (push (make-chat-code-symbol
               :name (match-string 1) :type 'function
               :line (line-number-at-pos))
              symbols)))
    symbols))

(defun chat-code-intel--parse-java-symbols ()
  "Parse Java methods and named type declarations."
  (let ((symbols (chat-code-intel--parse-c-like-functions)))
    (goto-char (point-min))
    (while (re-search-forward
            "^[[:space:]]*\\(?:public\\|protected\\|private\\|abstract\\|final\\|static\\|sealed\\|non-sealed\\|strictfp\\|[[:space:]]\\)*\\(class\\|interface\\|enum\\|record\\)[[:space:]]+\\([[:alpha:]_$][[:alnum:]_$]*\\)"
            nil t)
      (push (make-chat-code-symbol
             :name (match-string 2)
             :type (pcase (match-string 1)
                     ("interface" 'interface)
                     ("enum" 'enum)
                     (_ 'class))
             :line (line-number-at-pos))
            symbols))
    symbols))

(defun chat-code-intel--parse-c-family-symbols (language)
  "Parse C or C++ symbols for LANGUAGE."
  (let ((symbols (chat-code-intel--parse-c-like-functions)))
    (goto-char (point-min))
    (while (re-search-forward
            "^[[:space:]]*\\(?:typedef[[:space:]]+\\)?\\(struct\\|union\\|enum\\|class\\)[[:space:]]+\\([[:alpha:]_][[:alnum:]_]*\\)"
            nil t)
      (push (make-chat-code-symbol
             :name (match-string 2)
             :type (pcase (match-string 1)
                     ("enum" 'enum)
                     ("class" 'class)
                     (_ 'struct))
             :line (line-number-at-pos))
            symbols))
    (if (eq language 'cpp) symbols
      (seq-remove (lambda (symbol)
                    (eq (chat-code-symbol-type symbol) 'class))
                  symbols))))

(defun chat-code-intel--parse-sql-symbols ()
  "Parse SQL schema objects introduced by CREATE statements."
  (let ((case-fold-search t)
        symbols)
    (goto-char (point-min))
    (while (re-search-forward
            "^[[:space:]]*create[[:space:]]+\\(?:or[[:space:]]+replace[[:space:]]+\\)?\\(table\\|view\\|function\\|procedure\\|trigger\\)[[:space:]]+\\(?:if[[:space:]]+not[[:space:]]+exists[[:space:]]+\\)?[\"`[]?\\([[:alpha:]_][[:alnum:]_]*\\)"
            nil t)
      (push (make-chat-code-symbol
             :name (match-string 2)
             :type (pcase (downcase (match-string 1))
                     ("table" 'class)
                     ("view" 'interface)
                     ("trigger" 'method)
                     (_ 'function))
             :line (line-number-at-pos))
            symbols))
    symbols))

;; ------------------------------------------------------------------
;; Reference Indexing
;; ------------------------------------------------------------------

(defun chat-code-intel--index-file-references (index file-path)
  "Find references in FILE-PATH."
  (let ((symbols-table (chat-code-index-symbols index))
        (references-table (chat-code-index-references index)))
    (with-temp-buffer
      (insert-file-contents file-path)
      (goto-char (point-min))
      ;; Find identifier uses.  Definitions at their defining line are not
      ;; references; all other exact identifier occurrences are retained.
      ;; This catches function values, interface uses and Lisp calls instead
      ;; of limiting the index to C-style call syntax.
      (while (re-search-forward "\\_<\\([a-zA-Z_][a-zA-Z0-9_]*\\)\\_>" nil t)
        (let ((name (match-string 1)))
          (when (gethash name symbols-table)
            (let* ((line (line-number-at-pos))
                   (definition-p
                    (seq-some
                     (lambda (symbol)
                       (and (string= (chat-code-symbol-file symbol) file-path)
                            (= (chat-code-symbol-line symbol) line)))
                     (gethash name symbols-table))))
              (unless definition-p
                (let* ((after (save-excursion
                                (skip-chars-forward "[:space:]")
                                (char-after)))
                       (before (save-excursion
                                 (goto-char (match-beginning 1))
                                 (skip-chars-backward "[:space:]")
                                 (char-before)))
                       (ref (make-chat-code-reference
                             :symbol-name name
                             :file file-path
                             :line line
                             :column (save-excursion
                                       (goto-char (match-beginning 1))
                                       (current-column))
                             :type (if (or (eq after ?\() (eq before ?\())
                                       'call
                                     'reference))))
                  (puthash name
                           (cons ref (gethash name references-table))
                           references-table))))))))))

;; ------------------------------------------------------------------
;; Call Graph
;; ------------------------------------------------------------------

(defun chat-code-intel--build-call-graph (index)
  "Build call graph from references."
  (let ((call-graph (chat-code-index-call-graph index))
        (references (chat-code-index-references index)))
    (maphash (lambda (symbol-name refs)
               (dolist (ref refs)
                 (when (eq (chat-code-reference-type ref) 'call)
                   ;; symbol-name is called by function in ref-file
                   (let ((caller (chat-code-intel--find-containing-function
                                 index
                                 (chat-code-reference-file ref)
                                 (chat-code-reference-line ref))))
                     (when caller
                       (puthash caller
                               (cons symbol-name
                                     (gethash caller call-graph))
                               call-graph))))))
             references)))

(defun chat-code-intel--find-containing-function (index file line)
  "Find function containing FILE at LINE."
  (let ((symbols (chat-code-index-symbols index))
        best-name
        (best-line 0))
    (maphash (lambda (name syms)
               (dolist (sym syms)
                 (when (and (string= (chat-code-symbol-file sym) file)
                            (<= (chat-code-symbol-line sym) line)
                            (> (chat-code-symbol-line sym) best-line))
                   (setq best-name name
                         best-line (chat-code-symbol-line sym)))))
             symbols)
    best-name))

;; ------------------------------------------------------------------
;; Query Functions
;; ------------------------------------------------------------------

(defun chat-code-intel-find-definition (index symbol-name)
  "Find definition of SYMBOL-NAME in INDEX."
  (gethash symbol-name (chat-code-index-symbols index)))

(defun chat-code-intel-find-references (index symbol-name)
  "Find all references to SYMBOL-NAME in INDEX."
  (gethash symbol-name (chat-code-index-references index)))

(defun chat-code-intel-get-callees (index function-name)
  "Get functions called by FUNCTION-NAME."
  (gethash function-name (chat-code-index-call-graph index)))

(defun chat-code-intel-get-callers (index function-name)
  "Get functions that call FUNCTION-NAME."
  (let ((callers nil)
        (call-graph (chat-code-index-call-graph index)))
    (maphash (lambda (caller callees)
               (when (member function-name callees)
                 (push caller callers)))
             call-graph)
    callers))

;; ------------------------------------------------------------------
;; Smart Context
;; ------------------------------------------------------------------

(defun chat-code-intel-get-related-symbols (index symbol-name &optional depth)
  "Get symbols related to SYMBOL-NAME up to DEPTH levels.
Returns list of related symbol names."
  (let ((depth (or depth 2))
        (related (list symbol-name))
        (visited (make-hash-table :test 'equal)))
    (puthash symbol-name t visited)
    (dotimes (_ depth)
      (let ((new-related nil))
        (dolist (sym related)
          ;; Add callers
          (dolist (caller (chat-code-intel-get-callers index sym))
            (unless (gethash caller visited)
              (puthash caller t visited)
              (push caller new-related)))
          ;; Add callees
          (dolist (callee (chat-code-intel-get-callees index sym))
            (unless (gethash callee visited)
              (puthash callee t visited)
              (push callee new-related))))
        (setq related (append new-related related))))
    related))

(defun chat-code-intel-get-file-symbols (index file-path)
  "Get all symbols defined in FILE-PATH."
  (let (result)
    (maphash (lambda (_name syms)
               (dolist (sym syms)
                 (when (string= (chat-code-symbol-file sym) file-path)
                   (push sym result))))
             (chat-code-index-symbols index))
    result))

;; ------------------------------------------------------------------
;; Persistence
;; ------------------------------------------------------------------

(defun chat-code-intel--serialize-symbol (symbol)
  "Convert SYMBOL struct to an alist."
  `((name . ,(chat-code-symbol-name symbol))
    (type . ,(symbol-name (or (chat-code-symbol-type symbol) 'unknown)))
    (file . ,(chat-code-symbol-file symbol))
    (line . ,(chat-code-symbol-line symbol))
    (column . ,(chat-code-symbol-column symbol))
    (signature . ,(chat-code-symbol-signature symbol))
    (docstring . ,(chat-code-symbol-docstring symbol))))

(defun chat-code-intel--deserialize-symbol (data)
  "Build a symbol struct from DATA."
  (make-chat-code-symbol
   :name (alist-get 'name data)
   :type (intern (or (alist-get 'type data) "unknown"))
   :file (alist-get 'file data)
   :line (alist-get 'line data)
   :column (alist-get 'column data)
   :signature (alist-get 'signature data)
   :docstring (alist-get 'docstring data)))

(defun chat-code-intel--serialize-reference (reference)
  "Convert REFERENCE struct to an alist."
  `((symbol-name . ,(chat-code-reference-symbol-name reference))
    (file . ,(chat-code-reference-file reference))
    (line . ,(chat-code-reference-line reference))
    (column . ,(chat-code-reference-column reference))
    (type . ,(symbol-name (or (chat-code-reference-type reference) 'unknown)))))

(defun chat-code-intel--deserialize-reference (data)
  "Build a reference struct from DATA."
  (make-chat-code-reference
   :symbol-name (alist-get 'symbol-name data)
   :file (alist-get 'file data)
   :line (alist-get 'line data)
   :column (alist-get 'column data)
   :type (intern (or (alist-get 'type data) "unknown"))))

(defun chat-code-intel--serialize-hash-table (table value-fn)
  "Serialize TABLE using VALUE-FN for each element."
  (let (result)
    (maphash (lambda (key value)
               (push (cons key (mapcar value-fn value)) result))
             table)
    result))

(defun chat-code-intel--deserialize-hash-table (entries value-fn)
  "Deserialize ENTRIES using VALUE-FN into a hash table."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (entry entries)
      (puthash (if (symbolp (car entry))
                   (symbol-name (car entry))
                 (car entry))
               (mapcar value-fn (cdr entry))
               table))
    table))

(defun chat-code-intel--serialize-call-graph (call-graph)
  "Serialize CALL-GRAPH hash table."
  (let (result)
    (maphash (lambda (key value)
               (push (cons key value) result))
             call-graph)
    result))

(defun chat-code-intel--deserialize-call-graph (entries)
  "Deserialize call graph ENTRIES into a hash table."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (entry entries)
      (puthash (if (symbolp (car entry))
                   (symbol-name (car entry))
                 (car entry))
               (mapcar (lambda (item)
                         (if (symbolp item) (symbol-name item) item))
                       (cdr entry))
               table))
    table))

(defun chat-code-intel--ensure-directory ()
  "Ensure index directory exists."
  (unless (file-directory-p chat-code-intel-index-directory)
    (make-directory chat-code-intel-index-directory t)))

(defun chat-code-intel-save-index (index)
  "Save INDEX to disk."
  (chat-code-intel--ensure-directory)
  (let ((file (expand-file-name
               (format "%s.json" (md5 (chat-code-index-project-root index)))
               chat-code-intel-index-directory))
        (data `((project-root . ,(chat-code-index-project-root index))
                (files . ,(chat-code-index-files index))
                (symbols . ,(chat-code-intel--serialize-hash-table
                             (chat-code-index-symbols index)
                             #'chat-code-intel--serialize-symbol))
                (references . ,(chat-code-intel--serialize-hash-table
                                (chat-code-index-references index)
                                #'chat-code-intel--serialize-reference))
                (call-graph . ,(chat-code-intel--serialize-call-graph
                                (chat-code-index-call-graph index))))))
    (with-temp-file file
      (insert (json-encode data)))))

(defun chat-code-intel-load-index (project-root)
  "Load index for PROJECT-ROOT."
  (let ((file (expand-file-name
               (format "%s.json" (md5 project-root))
               chat-code-intel-index-directory)))
    (when (file-exists-p file)
      (let* ((json-object-type 'alist)
             (json-array-type 'list)
             (json-key-type 'symbol)
             (data (with-temp-buffer
                     (insert-file-contents file)
                     (json-read-from-string (buffer-string))))
             (index (make-chat-code-index
                     :project-root (or (alist-get 'project-root data) project-root)
                     :files (alist-get 'files data)
                     :symbols (chat-code-intel--deserialize-hash-table
                               (alist-get 'symbols data)
                               #'chat-code-intel--deserialize-symbol)
                     :references (chat-code-intel--deserialize-hash-table
                                  (alist-get 'references data)
                                  #'chat-code-intel--deserialize-reference)
                     :call-graph (chat-code-intel--deserialize-call-graph
                                  (alist-get 'call-graph data)))))
        (puthash project-root index chat-code-intel--active-indexes)
        index))))

;; ------------------------------------------------------------------
;; Commands
;; ------------------------------------------------------------------

;;;###autoload
(defun chat-code-index-project ()
  "Index the current project."
  (interactive)
  (chat-code-intel-index-project default-directory))

;;;###autoload
(defun chat-code-find-symbol (symbol-name)
  "Find SYMBOL-NAME in current project."
  (interactive "sSymbol name: ")
  (let* ((index (chat-code-intel-get-index default-directory))
         (symbols (and index (chat-code-intel-find-definition index symbol-name))))
    (if symbols
        (message "Found %d definition(s)" (length symbols))
      (message "Symbol not found"))))

;;;###autoload
(defun chat-code-find-references (symbol-name)
  "Find references to SYMBOL-NAME."
  (interactive "sSymbol name: ")
  (let* ((index (chat-code-intel-get-index default-directory))
         (refs (and index (chat-code-intel-find-references index symbol-name))))
    (message "Found %d reference(s)" (length refs))))

(provide 'chat-code-intel)
;;; chat-code-intel.el ends here
