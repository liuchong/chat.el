;;; test-chat-code-modules.el --- Tests for code mode support modules -*- lexical-binding: t -*-
;; Copyright (C) 2026 chat.el contributors
;; Author: chat.el contributors
;; Keywords: tests
;; This file is not part of GNU Emacs.
;;; Commentary:
;; Regression tests for repaired code mode support modules.
;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'test-helper)
(require 'chat-code)
(require 'chat-code-git)
(require 'chat-code-intel)
(require 'chat-code-perf)
(require 'chat-code-refactor)

(ert-deftest chat-code-parse-explicit-edit-builds-chat-edit ()
  "Test explicit code-edit JSON creates a usable `chat-edit' object."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (source-file (expand-file-name "sample.py" temp-dir))
          (session (chat-code-session-create "Explicit Edit" temp-dir source-file))
          edit)
     (with-temp-file source-file
       (insert "print('old')\n"))
     (with-temp-buffer
       (chat-code-mode)
       (setq-local chat-code--current-session session)
       (setq edit
             (chat-code--parse-explicit-edit
              (concat "```code-edit\n"
                      "{\"type\":\"rewrite\",\"file\":\"sample.py\",\"description\":\"Rewrite file\",\"new_content\":\"print('new')\\n\"}\n"
                      "```"))))
     (should (chat-edit-p edit))
     (should (equal (chat-edit-file edit) source-file))
     (should (equal (chat-edit-description edit) "Rewrite file"))
     (should (equal (chat-edit-new-content edit) "print('new')\n")))))

(ert-deftest chat-context-code-build-includes-project-agents-file ()
  "Test code context automatically includes project `AGENTS.md`."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (agents-file (expand-file-name "AGENTS.md" temp-dir))
          (source-file (expand-file-name "main.go" temp-dir))
          (session (chat-code-session-create "Agents Context" temp-dir source-file))
          context-string)
     (with-temp-file agents-file
       (insert "Project hard rule\nAlways verify code facts first.\n"))
     (with-temp-file source-file
       (insert "package main\nfunc main() {}\n"))
     (setf (chat-code-session-context-strategy session) 'minimal)
     (setq context-string
           (chat-context-code-to-string
            (chat-context-code-build session)))
     (should (string-match-p "Project Instructions: AGENTS.md" context-string))
     (should (string-match-p "Project hard rule" context-string))
     (should (string-match-p "Always verify code facts first" context-string)))))

(ert-deftest chat-code-view-preview-creates-preview-from-pending-edit ()
  "Test preview command materializes the preview buffer from a pending edit."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (source-file (expand-file-name "preview.py" temp-dir))
          (session (chat-code-session-create "Preview Session" temp-dir source-file))
          preview-buffer)
     (with-temp-file source-file
       (insert "print('old')\n"))
     (with-temp-buffer
       (chat-code-mode)
       (setq-local chat-code--current-session session)
       (chat-code--setup-buffer session)
       (setq-local chat-code--pending-edit
                   (chat-edit-create-rewrite
                    source-file
                    "print('old')\n"
                    "print('new')\n"
                    "Preview rewrite"))
       (cl-letf (((symbol-function 'pop-to-buffer)
                  (lambda (buffer &rest _)
                    (setq preview-buffer buffer)
                    buffer)))
         (chat-code-view-preview))
       (should (buffer-live-p preview-buffer))
       (should (chat-edit-preview-shown-p chat-code--pending-edit))
       (with-current-buffer preview-buffer
         (goto-char (point-min))
         (should (search-forward "Preview: " nil t))
         (should (search-forward "Preview rewrite" nil t)))))))

(ert-deftest chat-code-intel-save-and-load-index-roundtrip ()
  "Test index persistence saves and restores symbols, references, and call graph."
  (chat-test-with-temp-dir
   (let* ((chat-code-intel-index-directory temp-dir)
          (symbols (make-hash-table :test 'equal))
          (references (make-hash-table :test 'equal))
          (call-graph (make-hash-table :test 'equal))
          (index (make-chat-code-index
                  :project-root "/tmp/project"
                  :symbols symbols
                  :files '("/tmp/project/a.py")
                  :references references
                  :call-graph call-graph))
          loaded)
     (puthash "foo"
              (list (make-chat-code-symbol
                     :name "foo"
                     :type 'function
                     :file "/tmp/project/a.py"
                     :line 3))
              symbols)
     (puthash "foo"
              (list (make-chat-code-reference
                     :symbol-name "foo"
                     :file "/tmp/project/a.py"
                     :line 8
                     :type 'call))
              references)
     (puthash "caller" '("foo") call-graph)
     (chat-code-intel-save-index index)
     (setq chat-code-intel--active-indexes (make-hash-table :test 'equal))
     (setq loaded (chat-code-intel-load-index "/tmp/project"))
     (should (chat-code-index-p loaded))
     (should (equal (chat-code-index-files loaded) '("/tmp/project/a.py")))
     (should (= (length (gethash "foo" (chat-code-index-symbols loaded))) 1))
     (should (= (length (gethash "foo" (chat-code-index-references loaded))) 1))
     (should (equal (gethash "caller" (chat-code-index-call-graph loaded)) '("foo"))))))

(ert-deftest chat-code-git-run-normalizes-string-arguments ()
  "Test git helper splits string arguments into argv form."
  (should (equal (chat-code-git--argv "diff --cached --name-only")
                 '("diff" "--cached" "--name-only")))
  (should (equal (chat-code-git--argv '("status" "--short"))
                 '("status" "--short"))))

(ert-deftest chat-code-refactor-rename-creates-rewrite-edit ()
  "Test rename helper creates a whole-file rewrite edit."
  (chat-test-with-temp-dir
   (let* ((source-file (expand-file-name "rename.py" temp-dir))
          edits)
     (with-temp-file source-file
       (insert "def foo():\n    return foo_value\n"))
     (setq edits (chat-code-refactor--find-renames-in-file source-file "foo" "bar"))
     (should (= (length edits) 1))
     (should (equal (chat-edit-type (car edits)) 'rewrite))
     (should (string-match-p "bar" (chat-edit-new-content (car edits)))))))

(ert-deftest chat-code-perf-incremental-update-falls-back-to-full-index ()
  "Test incremental update performs a full index when no cached index exists."
  (let ((indexed nil)
        (updated nil)
        (fake-index (make-chat-code-index
                     :project-root "/tmp/project"
                     :symbols (make-hash-table :test 'equal)
                     :files '("a.py")
                     :references (make-hash-table :test 'equal)
                     :call-graph (make-hash-table :test 'equal))))
    (cl-letf (((symbol-function 'chat-code-intel-get-index)
               (lambda (_project-root) nil))
              ((symbol-function 'chat-code-intel-index-project)
               (lambda (_project-root)
                 (setq indexed t)
                 fake-index))
              ((symbol-function 'chat-code-perf-update-modtimes)
               (lambda (files)
                 (setq updated files))))
      (should (eq (chat-code-intel-incremental-update "/tmp/project") fake-index))
      (should indexed)
      (should (equal updated '("a.py"))))))

(provide 'test-chat-code-modules)
;;; test-chat-code-modules.el ends here
