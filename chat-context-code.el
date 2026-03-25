;;; chat-context-code.el --- Context management for code mode -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;; Author: chat.el contributors
;; Keywords: chat, code, context

;; This file is not part of GNU Emacs.

;;; Commentary:

;; This module provides intelligent context management for code mode.
;; It builds context from various sources based on the selected strategy.

;;; Code:

(require 'cl-lib)

;; ------------------------------------------------------------------
;; Customization
;; ------------------------------------------------------------------

(defgroup chat-context-code nil
  "Context management for code mode."
  :group 'chat-code
  :prefix "chat-context-code-")

(defcustom chat-context-code-token-budgets
  '((minimal . 2000)
    (focused . 4000)
    (balanced . 8000)
    (comprehensive . 16000))
  "Token budgets for each context strategy."
  :type '(alist :key-type symbol :value-type integer)
  :group 'chat-context-code)

(defcustom chat-context-code-max-file-size (* 100 1024)
  "Maximum file size in bytes to include in context."
  :type 'integer
  :group 'chat-context-code)

(defcustom chat-context-code-source-priorities
  '(focus-file            ; The file user is currently editing
    imports               ; Imported/required files
    related-symbols       ; Functions/classes referenced
    open-buffers          ; Other open code buffers
    git-modified          ; Recently modified files
    project-structure)    ; File tree overview
  "Priority order for context sources."
  :type '(repeat symbol)
  :group 'chat-context-code)

;; ------------------------------------------------------------------
;; Data Structures
;; ------------------------------------------------------------------

(cl-defstruct chat-code-context
  "Context object for code mode."
  strategy              ; Context strategy symbol
  budget                ; Token budget
  sources               ; List of context-source structs
  files                 ; List of file-context structs
  symbols               ; List of relevant symbols
  total-tokens)         ; Estimated total tokens

(cl-defstruct chat-code-context-source
  "A source of context information."
  type                  ; Source type symbol
  priority              ; Priority number (lower = higher)
  content               ; Content string
  tokens                ; Estimated token count
  metadata)             ; Additional metadata

(cl-defstruct chat-code-file-context
  "Context for a single file."
  path                  ; File path
  language              ; Language symbol
  content               ; File content or excerpt
  line-range            ; (start . end) or nil for whole file
  symbols               ; List of symbols defined in file
  size                  ; Content size in characters
  tokens)               ; Estimated token count

;; ------------------------------------------------------------------
;; Token Estimation
;; ------------------------------------------------------------------

(defun chat-context-code--estimate-tokens (text)
  "Estimate token count for TEXT.
Uses a simple heuristic: ~4 characters per token on average."
  (max 1 (/ (length text) 4)))

(defun chat-context-code--calculate-budget (strategy)
  "Get token budget for STRATEGY."
  (or (cdr (assoc strategy chat-context-code-token-budgets))
      8000)) ;; Default to balanced

;; ------------------------------------------------------------------
;; Smart Context Building with Symbol Intelligence
;; ------------------------------------------------------------------

(defun chat-context-code-build (code-session)
  "Build context for CODE-SESSION based on its strategy.
Uses symbol index for smart context when available."
  (let* ((strategy (chat-code-session-context-strategy code-session))
         (budget (chat-context-code--calculate-budget strategy))
         (context (make-chat-code-context
                   :strategy strategy
                   :budget budget
                   :sources nil
                   :files nil
                   :symbols nil
                   :total-tokens 0)))
    ;; Try to use symbol index for smart context
    (when (featurep 'chat-code-intel)
      (let ((index (chat-code-intel-get-index
                    (chat-code-session-project-root code-session))))
        (when index
          (chat-context-code--add-symbol-context context code-session index))))
    ;; Build context based on strategy
    (pcase strategy
      ('minimal (chat-context-code--build-minimal context code-session))
      ('focused (chat-context-code--build-focused context code-session))
      ('balanced (chat-context-code--build-balanced context code-session))
      ('comprehensive (chat-context-code--build-comprehensive context code-session))
      (_ (chat-context-code--build-balanced context code-session)))
    ;; Optimize to fit budget
    (chat-context-code--optimize context)
    context))

(defun chat-context-code--add-symbol-context (context code-session index)
  "Add symbol-based context from INDEX to CONTEXT."
  (let ((focus-file (chat-code-session-focus-file code-session)))
    (when focus-file
      ;; Get symbols from focus file
      (let ((file-symbols (chat-code-intel-get-file-symbols index focus-file)))
        (when file-symbols
          ;; Add related symbols
          (dolist (sym (cl-subseq file-symbols 0 (min 5 (length file-symbols))))
            (let* ((name (chat-code-symbol-name sym))
                   (related (chat-code-intel-get-related-symbols index name 1)))
              (dolist (rel-name related)
                (unless (string= rel-name name)
                  (let ((rel-syms (chat-code-intel-find-definition index rel-name)))
                    (dolist (rel-sym rel-syms)
                      (push (format ";; Related: %s (defined in %s:%d)"
                                    rel-name
                                    (chat-code-symbol-file rel-sym)
                                    (chat-code-symbol-line rel-sym))
                            (chat-code-context-symbols context)))))))))))))

(defun chat-context-code--build-minimal (context code-session)
  "Build minimal context: just the focus file."
  (let ((focus-file (chat-code-session-focus-file code-session)))
    (when focus-file
      (chat-context-code--add-file context focus-file))
    context))

(defun chat-context-code--build-focused (context code-session)
  "Build focused context: focus file + related files."
  ;; Add focus file
  (let ((focus-file (chat-code-session-focus-file code-session)))
    (when focus-file
      (chat-context-code--add-file context focus-file)))
  ;; Add context files
  (dolist (file (chat-code-session-context-files code-session))
    (unless (chat-context-code--file-in-context-p context file)
      (chat-context-code--add-file context file :max-lines 50)))
  context)

(defun chat-context-code--build-balanced (context code-session)
  "Build balanced context: files + imports + symbols."
  ;; Add focus file with full content
  (let ((focus-file (chat-code-session-focus-file code-session)))
    (when focus-file
      (chat-context-code--add-file context focus-file :with-symbols t)))
  ;; Add related files (truncated)
  (dolist (file (chat-code-session-context-files code-session))
    (unless (chat-context-code--file-in-context-p context file)
      (chat-context-code--add-file context file :max-lines 30 :with-outline t)))
  ;; Add import information
  (chat-context-code--add-imports context code-session)
  context)

(defun chat-context-code--build-comprehensive (context code-session)
  "Build comprehensive context: extensive project information."
  ;; Add focus file
  (let ((focus-file (chat-code-session-focus-file code-session)))
    (when focus-file
      (chat-context-code--add-file context focus-file :with-symbols t)))
  ;; Add all context files
  (dolist (file (chat-code-session-context-files code-session))
    (unless (chat-context-code--file-in-context-p context file)
      (chat-context-code--add-file context file)))
  ;; Add imports
  (chat-context-code--add-imports context code-session)
  ;; Add project structure
  (chat-context-code--add-project-structure context code-session)
  context)

;; ------------------------------------------------------------------
;; File Operations
;; ------------------------------------------------------------------

(defun chat-context-code--file-in-context-p (context file-path)
  "Check if FILE-PATH is already in CONTEXT."
  (cl-some (lambda (fc)
             (string= (chat-code-file-context-path fc) file-path))
           (chat-code-context-files context)))

(defun chat-context-code--add-file (context file-path &rest options)
  "Add FILE-PATH to CONTEXT with OPTIONS.
OPTIONS:
  :max-lines - Maximum lines to read
  :with-symbols - Include symbol information
  :with-outline - Include file outline only"
  (let* ((max-lines (plist-get options :max-lines))
         (with-symbols (plist-get options :with-symbols))
         (with-outline (plist-get options :with-outline))
         (language (chat-context-code--detect-language file-path))
         content)
    (when (and (file-exists-p file-path)
               (< (file-attribute-size (file-attributes file-path))
                  chat-context-code-max-file-size))
      ;; Read content
      (setq content (chat-context-code--read-file-content
                     file-path max-lines with-outline))
      (when content
        (let* ((tokens (chat-context-code--estimate-tokens content))
               (file-ctx (make-chat-code-file-context
                          :path file-path
                          :language language
                          :content content
                          :line-range (when max-lines (cons 1 max-lines))
                          :symbols (when with-symbols
                                     (chat-context-code--extract-symbols
                                      file-path language))
                          :size (length content)
                          :tokens tokens)))
          (push file-ctx (chat-code-context-files context))
          (cl-incf (chat-code-context-total-tokens context) tokens))))
  context)

(defun chat-context-code--read-file-content (file-path &optional max-lines outline-only)
  "Read content of FILE-PATH.
If MAX-LINES is set, read only that many lines.
If OUTLINE-ONLY is t, extract only function/class signatures."
  (with-temp-buffer
    (condition-case nil
        (progn
          (insert-file-contents file-path)
          (when max-lines
            (goto-line (1+ max-lines))
            (delete-region (point) (point-max)))
          (when outline-only
            (chat-context-code--extract-outline (current-buffer)))
          (buffer-string))
      (error nil))))

(defun chat-context-code--extract-outline (buffer)
  "Extract function/class signatures from BUFFER."
  ;; This is a simplified version
  ;; Language-specific extraction would be better
  (with-current-buffer buffer
    (let ((outline-lines '()))
      (goto-char (point-min))
      ;; Simple pattern matching for common languages
      (while (re-search-forward "^[[:space:]]*\\(def\\|class\\|function\\)\\s-+\\([^(]+\\)" nil t))
        (push (buffer-substring-no-properties
               (line-beginning-position)
               (line-end-position))
              outline-lines))
      (when outline-lines
        (goto-char (point-max))
        (insert "\n\n;; Outline:\n")
        (dolist (line (nreverse outline-lines))
          (insert ";; " line "\n"))))))

(defun chat-context-code--extract-symbols (file-path language)
  "Extract symbols from FILE-PATH based on LANGUAGE."
  ;; Placeholder - would use language-specific parsing
  (with-temp-buffer
    (insert-file-contents file-path)
    (let (symbols)
      (goto-char (point-min))
      (while (re-search-forward "^\\s-*\\(def\\|class\\)\\s-+\\([^(]+\\)" nil t)
        (push (match-string 2) symbols))
      symbols)))

(defun chat-context-code--detect-language (file-path)
  "Detect programming language for FILE-PATH."
  (let ((ext (file-name-extension file-path)))
    (pcase ext
      ("py" 'python)
      ("js" 'javascript)
      ("ts" 'typescript)
      ("el" 'emacs-lisp)
      ("go" 'go)
      ("rs" 'rust)
      ("rb" 'ruby)
      ("java" 'java)
      (_ nil))))

;; ------------------------------------------------------------------
;; Import Analysis
;; ------------------------------------------------------------------

(defun chat-context-code--add-imports (context code-session)
  "Add import information to CONTEXT from CODE-SESSION."
  ;; This is a placeholder implementation
  ;; Would need language-specific import extraction
  (let ((focus-file (chat-code-session-focus-file code-session)))
    (when focus-file
      (let ((imports (chat-context-code--extract-imports focus-file)))
        (when imports
          (let* ((content (format ";; Imports from %s:\n%s\n"
                                  (file-name-nondirectory focus-file)
                                  (mapconcat #'identity imports "\n")))
                 (tokens (chat-context-code--estimate-tokens content))
                 (source (make-chat-code-context-source
                          :type 'imports
                          :priority 2
                          :content content
                          :tokens tokens
                          :metadata nil)))
            (push source (chat-code-context-sources context))
            (cl-incf (chat-code-context-total-tokens context) tokens))))))
  context)

(defun chat-context-code--extract-imports (file-path)
  "Extract import statements from FILE-PATH."
  (with-temp-buffer
    (insert-file-contents file-path)
    (let (imports)
      (goto-char (point-min))
      ;; Python imports
      (while (re-search-forward "^\\(import\\|from\\)\\s-+\\([^\n]+\\)" nil t)
        (push (match-string 0) imports))
      ;; JavaScript/TypeScript imports
      (goto-char (point-min))
      (while (re-search-forward "^\\(import\\|require\\|export\\)\\s-*[^\n]*" nil t)
        (unless (member (match-string 0) imports)
          (push (match-string 0) imports)))
      (nreverse imports))))

;; ------------------------------------------------------------------
;; Project Structure
;; ------------------------------------------------------------------

(defun chat-context-code--add-project-structure (context code-session)
  "Add project structure to CONTEXT."
  (let* ((root (chat-code-session-project-root code-session))
         (structure (chat-context-code--get-project-structure root)))
    (when structure
      (let* ((content (format ";; Project Structure:\n%s\n" structure))
             (tokens (chat-context-code--estimate-tokens content))
             (source (make-chat-code-context-source
                      :type 'project-structure
                      :priority 5
                      :content content
                      :tokens tokens
                      :metadata `((root . ,root)))))
        (push source (chat-code-context-sources context))
        (cl-incf (chat-code-context-total-tokens context) tokens))))
  context)

(defun chat-context-code--get-project-structure (root &optional depth)
  "Get project structure as string, limited to DEPTH levels."
  (let ((depth (or depth 2))
        (result ""))
    (with-temp-buffer
      (cd root)
      ;; Use find to get directory structure
      (call-process "find" nil t nil
                    "." "-maxdepth" (number-to-string depth)
                    "-type" "f"
                    "!" "-path" "./.git/*"
                    "!" "-path" "./node_modules/*"
                    "!" "-path" "./__pycache__/*"
                    "!" "-path" "./.venv/*")
      (setq result (buffer-string)))
    result))

;; ------------------------------------------------------------------
;; Optimization
;; ------------------------------------------------------------------

(defun chat-context-code--optimize (context)
  "Optimize CONTEXT to fit within budget."
  (let ((budget (chat-code-context-budget context))
        (total (chat-code-context-total-tokens context)))
    ;; If over budget, truncate content
    (while (> total budget)
      (let ((file-to-truncate (chat-context-code--find-largest-file context)))
        (if file-to-truncate
            (progn
              (chat-context-code--truncate-file-context file-to-truncate)
              (setq total (chat-context-code--recalculate-tokens context)))
          ;; No more files to truncate, remove lowest priority source
          (chat-context-code--remove-lowest-priority context)
          (setq total (chat-context-code--recalculate-tokens context)))))
    ;; Update total
    (setf (chat-code-context-total-tokens context) total)))

(defun chat-context-code--find-largest-file (context)
  "Find the largest file context that can be truncated."
  (cl-find-if (lambda (fc)
                (and (> (chat-code-file-context-tokens fc) 100)
                     (null (chat-code-file-context-line-range fc))))
              (chat-code-context-files context)))

(defun chat-context-code--truncate-file-context (file-ctx)
  "Truncate FILE-CTX to reduce token count."
  (let ((current-content (chat-code-file-context-content file-ctx))
        (lines (split-string (chat-code-file-context-content file-ctx) "\n")))
    ;; Keep first half and add ellipsis
    (let ((new-lines (append (cl-subseq lines 0 (max 10 (/ (length lines) 2)))
                            (list "\n;; ... [truncated] ...\n"))))
      (setf (chat-code-file-context-content file-ctx)
            (mapconcat #'identity new-lines "\n"))
      (setf (chat-code-file-context-tokens file-ctx)
            (chat-context-code--estimate-tokens
             (chat-code-file-context-content file-ctx))))))

(defun chat-context-code--remove-lowest-priority (context)
  "Remove the lowest priority source from CONTEXT."
  (let ((sources (chat-code-context-sources context)))
    (when sources
      (let ((lowest (cl-reduce (lambda (a b)
                                (if (> (chat-code-context-source-priority a)
                                       (chat-code-context-source-priority b))
                                    a b))
                              sources)))
        (setf (chat-code-context-sources context)
              (delete lowest sources))))))

(defun chat-context-code--recalculate-tokens (context)
  "Recalculate total tokens for CONTEXT."
  (let ((total 0))
    (dolist (fc (chat-code-context-files context))
      (cl-incf total (chat-code-file-context-tokens fc)))
    (dolist (src (chat-code-context-sources context))
      (cl-incf total (chat-code-context-source-tokens src)))
    total))

;; ------------------------------------------------------------------
;; Output Formatting
;; ------------------------------------------------------------------

(defun chat-context-code-to-string (context)
  "Convert CONTEXT to a string for LLM prompt."
  (with-temp-buffer
    ;; Add strategy info
    (insert (format ";; Context Strategy: %s\n"
                    (chat-code-context-strategy context)))
    (insert (format ";; Files: %d, Estimated tokens: %d/%d\n\n"
                    (length (chat-code-context-files context))
                    (chat-code-context-total-tokens context)
                    (chat-code-context-budget context)))
    ;; Add sources
    (dolist (source (sort (chat-code-context-sources context)
                          (lambda (a b)
                            (< (chat-code-context-source-priority a)
                               (chat-code-context-source-priority b)))))
      (insert (chat-code-context-source-content source))
      (insert "\n"))
    ;; Add files
    (dolist (file-ctx (chat-code-context-files context))
      (insert (format ";; File: %s (%s)\n"
                      (chat-code-file-context-path file-ctx)
                      (or (chat-code-file-context-language file-ctx) "unknown")))
      (when (chat-code-file-context-symbols file-ctx)
        (insert (format ";; Symbols: %s\n"
                        (mapconcat #'identity
                                   (chat-code-file-context-symbols file-ctx)
                                   ", "))))
      (insert "```\n")
      (insert (chat-code-file-context-content file-ctx))
      (unless (string-suffix-p "\n" (chat-code-file-context-content file-ctx))
        (insert "\n"))
      (insert "```\n\n"))
    (buffer-string)))

;; ------------------------------------------------------------------
;; Utilities
;; ------------------------------------------------------------------

(defun chat-context-code-get-file-content (context file-path)
  "Get content of FILE-PATH from CONTEXT."
  (cl-find-if (lambda (fc)
                (string= (chat-code-file-context-path fc) file-path))
              (chat-code-context-files context)))

(defun chat-context-code-add-file (context file-path)
  "Manually add FILE-PATH to CONTEXT."
  (unless (chat-context-code--file-in-context-p context file-path)
    (chat-context-code--add-file context file-path))
  context)

(defun chat-context-code-remove-file (context file-path)
  "Remove FILE-PATH from CONTEXT."
  (setf (chat-code-context-files context)
        (cl-remove-if (lambda (fc)
                        (string= (chat-code-file-context-path fc) file-path))
                      (chat-code-context-files context)))
  (chat-context-code--recalculate-tokens context)
  context)

;; ------------------------------------------------------------------
;; Provide
;; ------------------------------------------------------------------

(provide 'chat-context-code)
;;; chat-context-code.el ends here
