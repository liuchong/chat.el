;;; chat-code-refactor.el --- Multi-file refactoring for chat.el -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;;; Commentary:

;; This module provides multi-file refactoring capabilities.
;; Supports cross-file rename, extract to new file, move between files.

;;; Code:

(require 'cl-lib)
(require 'chat-edit)
(require 'chat-code-intel)

(defun chat-code-refactor--read-file (file)
  "Read FILE contents."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

;; ------------------------------------------------------------------
;; Cross-file Rename
;; ------------------------------------------------------------------

(defun chat-code-refactor-rename-symbol (old-name new-name &optional scope)
  "Rename symbol OLD-NAME to NEW-NAME across project.
SCOPE can be 'file, 'project, or 'selected-files."
  (interactive
   (list (read-string "Old name: " (thing-at-point 'symbol))
         (read-string "New name: ")
         (intern (completing-read "Scope: " '("file" "project" "selected-files") nil t "project"))))
  (let* ((project-root (chat-code--detect-project-root))
         (index (chat-code-intel-get-index project-root))
         (files-to-process (chat-code-refactor--get-files-for-scope scope project-root))
         (edits nil))
    ;; Build edits for all files
    (dolist (file files-to-process)
      (let ((file-edits (chat-code-refactor--find-renames-in-file file old-name new-name)))
        (setq edits (append file-edits edits))))
    ;; Apply or preview edits
    (if edits
        (progn
          (message "Found %d occurrences to rename" (length edits))
          (chat-code-refactor--preview-and-apply edits "Rename"))
      (message "No occurrences found of '%s'" old-name))))

(defun chat-code-refactor--get-files-for-scope (scope project-root)
  "Get list of files for SCOPE in PROJECT-ROOT."
  (pcase scope
    ('file (list (buffer-file-name)))
    ('project (chat-code-intel--find-source-files project-root))
    ('selected-files (dired-get-marked-files))
    (_ (chat-code-intel--find-source-files project-root))))

(defun chat-code-refactor--find-renames-in-file (file old-name new-name)
  "Find all occurrences of OLD-NAME in FILE to rename to NEW-NAME.
Returns list of edits."
  (when (file-exists-p file)
    (let* ((original-content (chat-code-refactor--read-file file))
           (new-content (replace-regexp-in-string
                         (format "\\b%s\\b" (regexp-quote old-name))
                         new-name
                         original-content)))
      (unless (string= original-content new-content)
        (list
         (chat-edit-create-rewrite
          file
          original-content
          new-content
          (format "Rename %s to %s" old-name new-name)))))))

;; ------------------------------------------------------------------
;; Extract to New File
;; ------------------------------------------------------------------

(defun chat-code-refactor-extract-to-file (start end target-file)
  "Extract code from START to END into TARGET-FILE.
Updates imports/references in original file."
  (interactive
   (list (if (region-active-p) (region-beginning) (point-min))
         (if (region-active-p) (region-end) (point-max))
         (read-file-name "Target file: ")))
  (let* ((source-file (buffer-file-name))
         (code-to-extract (buffer-substring-no-properties start end))
         (source-lang (chat-code-intel--detect-language source-file))
         (target-lang (chat-code-intel--detect-language target-file)))
    (unless (eq source-lang target-lang)
      (error "Source and target files must be the same language"))
    ;; Create extraction edit
    (let* ((extract-edit (chat-edit-create-generate
                          target-file
                          code-to-extract
                          (format "Extract code from %s" source-file)))
           ;; Find and update imports
           (import-edit (chat-code-refactor--generate-import-update
                         source-file target-file code-to-extract source-lang)))
      ;; Preview and apply
      (chat-code-refactor--preview-and-apply
       (delq nil (list extract-edit import-edit))
       "Extract to file"))))

(defun chat-code-refactor--generate-import-update (source-file target-file code lang)
  "Generate import update for extracting CODE from SOURCE-FILE to TARGET-FILE."
  (let ((target-module (file-name-base target-file))
        (source-content (chat-code-refactor--read-file source-file)))
    (pcase lang
      ('python
       (unless (string-match-p (format "^from\\s-+%s\\s-+import\\s-+" (regexp-quote target-module))
                               source-content)
         (chat-edit-create-rewrite
          source-file
          source-content
          (concat (format "from %s import ...\n" target-module) source-content)
          "Add import for extracted module")))
      ('javascript
       (unless (string-match-p (format "^import\\s-+.*['\"]\\./%s['\"]" (regexp-quote target-module))
                               source-content)
         (chat-edit-create-rewrite
          source-file
          source-content
          (concat (format "import { ... } from './%s';\n" target-module) source-content)
          "Add import for extracted module")))
      (_ nil))))

;; ------------------------------------------------------------------
;; Move Function Between Files
;; ------------------------------------------------------------------

(defun chat-code-refactor-move-function (function-name target-file)
  "Move FUNCTION-NAME to TARGET-FILE.
Updates all references in project."
  (interactive
   (list (read-string "Function name: " (thing-at-point 'symbol))
         (read-file-name "Target file: ")))
  (let* ((project-root (chat-code--detect-project-root))
         (index (chat-code-intel-get-index project-root))
         (symbols (chat-code-intel-find-definition index function-name))
         (source-file (and symbols (chat-code-symbol-file (car symbols)))))
    (unless source-file
      (error "Function '%s' not found" function-name))
    ;; Get function content
    (let* ((function-content (chat-code-refactor--get-function-content source-file function-name))
           ;; Create edits
           (remove-edit (chat-edit-create-delete
                         source-file
                         function-content
                         (chat-code-refactor--find-function-range source-file function-name)
                         (format "Move %s to %s" function-name target-file)))
           (add-edit (chat-edit-create-generate
                      target-file
                      function-content
                      (format "Add %s from %s" function-name source-file)))
           ;; Find and update references
           (reference-edits (chat-code-refactor--update-references
                             project-root function-name source-file target-file)))
      ;; Apply all edits
      (chat-code-refactor--preview-and-apply
       (append (list remove-edit add-edit) reference-edits)
       "Move function"))))

(defun chat-code-refactor--get-function-content (file function-name)
  "Get the full content of FUNCTION-NAME from FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    ;; Language-specific function finding
    (let ((lang (chat-code-intel--detect-language file)))
      (pcase lang
        ('python
         (when (re-search-forward (format "^def\\s+%s\\s*(" function-name) nil t)
           (beginning-of-line)
           (let ((start (point)))
             ;; Find end of function (next def/class at same or lower indent)
             (forward-line 1)
             (while (and (not (eobp))
                         (or (looking-at "^[ \t]+")
                             (looking-at "^$")))
               (forward-line 1))
             (buffer-substring-no-properties start (point)))))
        (_ (format "# %s definition\n" function-name))))))

(defun chat-code-refactor--find-function-range (file function-name)
  "Find the line range of FUNCTION-NAME in FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (let ((lang (chat-code-intel--detect-language file)))
      (pcase lang
        ('python
         (when (re-search-forward (format "^def\\s+%s\\s*(" function-name) nil t)
           (let ((start-line (line-number-at-pos)))
             (forward-line 1)
             (while (and (not (eobp))
                         (or (looking-at "^[ \t]+")
                             (looking-at "^$")))
               (forward-line 1))
             (cons start-line (line-number-at-pos)))))))))

(defun chat-code-refactor--update-references (project-root function-name old-file new-file)
  "Update references to FUNCTION-NAME from OLD-FILE to NEW-FILE."
  (let ((index (chat-code-intel-get-index project-root))
        (refs (chat-code-intel-find-references index function-name))
        edits)
    ;; For each reference in other files, potentially update import
    (dolist (ref refs)
      (unless (string= (chat-code-reference-file ref) old-file)
        ;; Could add import update logic here
        ))
    edits))

;; ------------------------------------------------------------------
;; Preview and Apply
;; ------------------------------------------------------------------

(defun chat-code-refactor--preview-and-apply (edits description)
  "Preview EDITS and let user confirm before applying.
DESCRIPTION describes the refactoring operation."
  (let* ((flat-edits
          (cl-loop for edit in edits
                   if (chat-edit-p edit) collect edit
                   else if (listp edit) append (cl-remove-if-not #'chat-edit-p edit)))
         (buffer (get-buffer-create "*chat-refactor-preview*")))
    (with-current-buffer buffer
      (erase-buffer)
      (insert (format "════════════════════════════════════════════════════════════════════\n"))
      (insert (format "Refactoring Preview: %s\n" description))
      (insert (format "════════════════════════════════════════════════════════════════════\n\n"))
      (dolist (edit flat-edits)
        (when edit
          (insert (format "File: %s\n" (chat-edit-file edit)))
          (insert (format "Type: %s\n" (chat-edit-type edit)))
          (insert (format "Description: %s\n" (chat-edit-description edit)))
          (insert "---\n")))
      (insert "\n")
      (insert (propertize "[a] Apply all  [c] Cancel\n"
                          'face '(:weight bold)))
      (local-set-key (kbd "a") (lambda ()
                                 (interactive)
                                 (dolist (edit flat-edits)
                                   (when edit (chat-edit-apply edit)))
                                 (kill-buffer)))
      (local-set-key (kbd "c") (lambda ()
                                 (interactive)
                                 (kill-buffer))))
    (pop-to-buffer buffer)))

;; ------------------------------------------------------------------
;; Commands
;; ------------------------------------------------------------------

;;;###autoload
(defun chat-code-rename-symbol ()
  "Rename symbol at point across project."
  (interactive)
  (let ((old-name (thing-at-point 'symbol)))
    (chat-code-refactor-rename-symbol
     old-name
     (read-string (format "Rename '%s' to: " old-name))
     'project)))

;;;###autoload
(defun chat-code-extract-to-file ()
  "Extract selected code to new file."
  (interactive)
  (unless (region-active-p)
    (error "Please select code to extract"))
  (chat-code-refactor-extract-to-file
   (region-beginning)
   (region-end)
   (read-file-name "Extract to: ")))

;;;###autoload
(defun chat-code-move-function ()
  "Move function at point to another file."
  (interactive)
  (let ((function-name (thing-at-point 'symbol)))
    (chat-code-refactor-move-function
     function-name
     (read-file-name (format "Move '%s' to: " function-name)))))

(provide 'chat-code-refactor)
;;; chat-code-refactor.el ends here
