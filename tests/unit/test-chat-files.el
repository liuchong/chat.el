;;; test-chat-files.el --- Tests for chat-files.el -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: tests

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Unit tests for chat-files.el file operations module.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'test-helper)
(require 'chat-files)

;; ------------------------------------------------------------------
;; Security and Path Validation
;; ------------------------------------------------------------------

(ert-deftest chat-files-safe-path-allows-valid-paths ()
  "Test that valid paths are accepted."
  (let ((chat-files-allowed-directories '("~/test/"))
        (chat-files-deny-patterns nil))
    (should (chat-files--safe-path-p "~/test/file.txt"))))

(ert-deftest chat-files-safe-path-rejects-outside-allowed ()
  "Test that paths outside allowed directories are rejected."
  (let ((chat-files-allowed-directories '("~/safe/")))
    (should-error (chat-files--safe-path-p "~/outside/file.txt"))))

(ert-deftest chat-files-safe-path-rejects-denied-patterns ()
  "Test that denied file patterns are rejected."
  (let ((chat-files-allowed-directories '("~/"))
        (chat-files-deny-patterns '("\\.key$")))
    (should-error (chat-files--safe-path-p "~/secret.key"))))

(ert-deftest chat-files-safe-path-rejects-symlink-escaping-allowed-root ()
  "Test that symlinks cannot escape the allowed root."
  (skip-unless (fboundp 'make-symbolic-link))
  (chat-test-with-temp-dir
   (let* ((outside-dir (make-temp-file "chat-outside-" t))
          (link-path (expand-file-name "escape-link" temp-dir))
          (chat-files-allowed-directories (list temp-dir)))
     (unwind-protect
         (progn
           (make-symbolic-link outside-dir link-path t)
           (should-error (chat-files--safe-path-p (expand-file-name "secret.txt" link-path))))
       (when (file-directory-p outside-dir)
         (delete-directory outside-dir t))))))

(ert-deftest chat-files-default-allowed-directories-do-not-include-home-root ()
  "Test default file access is not the entire home directory."
  (should-not (member "~/" chat-files-allowed-directories)))

;; ------------------------------------------------------------------
;; Basic File Operations
;; ------------------------------------------------------------------

(ert-deftest chat-files-read-existing-file ()
  "Test reading content from existing file."
  (chat-test-with-temp-dir
   (let* ((test-file (expand-file-name "test.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir)))
     (with-temp-file test-file
       (insert "Hello World"))
     (let ((result (chat-files-read test-file)))
       (should (plistp result))
       (should (string= (plist-get result :content) "Hello World"))
       (should (equal (plist-get result :path) (file-truename test-file)))))))

(ert-deftest chat-files-read-lines-specific-range ()
  "Test reading specific line range."
  (chat-test-with-temp-dir
   (let* ((test-file (expand-file-name "test.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir)))
     (with-temp-file test-file
       (insert "line1\nline2\nline3\nline4\nline5\n"))
     (let ((result (chat-files-read-lines test-file 2 3)))
       (should (= (plist-get result :start) 2))
       (should (= (plist-get result :end) 4))
       (should (= (length (plist-get result :lines)) 3))
       (should (string= (car (plist-get result :lines)) "line2"))))))

(ert-deftest chat-files-exists-p-checks-file ()
  "Test file existence check."
  (chat-test-with-temp-dir
   (let* ((test-file (expand-file-name "exists.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir)))
     (with-temp-file test-file nil)
     (let ((result (chat-files-exists-p test-file)))
       (should (plist-get result :exists))
       (should (eq (plist-get result :type) 'file))))))

(ert-deftest chat-files-list-directory ()
  "Test listing directory contents."
  (chat-test-with-temp-dir
   (let ((chat-files-allowed-directories (list temp-dir)))
     (with-temp-file (expand-file-name "file1.txt" temp-dir) nil)
     (with-temp-file (expand-file-name "file2.txt" temp-dir) nil)
     (make-directory (expand-file-name "subdir" temp-dir))
     (let ((result (chat-files-list temp-dir)))
       (should (= (length result) 3))))))

(ert-deftest chat-files-list-recursive-keeps-plist-shape ()
  "Test recursive listing returns plist entries like non recursive mode."
  (chat-test-with-temp-dir
   (let ((chat-files-allowed-directories (list temp-dir)))
     (make-directory (expand-file-name "sub" temp-dir))
     (with-temp-file (expand-file-name "sub/file.txt" temp-dir) nil)
     (let ((result (chat-files-list temp-dir "file\\.txt$" t)))
       (should (= (length result) 1))
       (should (plist-get (car result) :path))
       (should (equal (plist-get (car result) :type) 'file))))))

;; ------------------------------------------------------------------
;; File Movement
;; ------------------------------------------------------------------

(ert-deftest chat-files-move-renames-file ()
  "Test moving or renaming a file."
  (chat-test-with-temp-dir
   (let* ((source (expand-file-name "old.txt" temp-dir))
          (dest (expand-file-name "new.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir)))
     (with-temp-file source
       (insert "content"))
     (chat-files-move source dest)
     (should-not (file-exists-p source))
     (should (file-exists-p dest))
     (should (string= (with-temp-buffer
                        (insert-file-contents dest)
                        (buffer-string))
                      "content")))))

(ert-deftest chat-files-copy-duplicates-file ()
  "Test copying a file."
  (chat-test-with-temp-dir
   (let* ((source (expand-file-name "source.txt" temp-dir))
          (dest (expand-file-name "dest.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir)))
     (with-temp-file source
       (insert "original"))
     (chat-files-copy source dest)
     (should (file-exists-p source))
     (should (file-exists-p dest))
     (should (string= (with-temp-buffer
                        (insert-file-contents dest)
                        (buffer-string))
                      "original")))))

(ert-deftest chat-files-delete-removes-file ()
  "Test deleting a file."
  (chat-test-with-temp-dir
   (let* ((test-file (expand-file-name "delete.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir)))
     (with-temp-file test-file nil)
     (should (file-exists-p test-file))
     (chat-files-delete test-file)
     (should-not (file-exists-p test-file)))))

(ert-deftest chat-files-mkdir-creates-directory ()
  "Test creating a directory."
  (chat-test-with-temp-dir
   (let* ((new-dir (expand-file-name "newdir" temp-dir))
          (chat-files-allowed-directories (list temp-dir)))
     (chat-files-mkdir new-dir)
     (should (file-directory-p new-dir)))))

;; ------------------------------------------------------------------
;; Content Modification
;; ------------------------------------------------------------------

(ert-deftest chat-files-write-creates-file ()
  "Test writing content to new file."
  (chat-test-with-temp-dir
   (let* ((test-file (expand-file-name "write.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir)))
     (chat-files-write test-file "new content")
     (should (file-exists-p test-file))
     (should (string= (with-temp-buffer
                        (insert-file-contents test-file)
                        (buffer-string))
                      "new content")))))

(ert-deftest chat-files-write-appends-content ()
  "Test appending content to file."
  (chat-test-with-temp-dir
   (let* ((test-file (expand-file-name "append.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir)))
     (chat-files-write test-file "first ")
     (chat-files-write test-file "second" t)
     (should (string= (with-temp-buffer
                        (insert-file-contents test-file)
                        (buffer-string))
                      "first second")))))

(ert-deftest chat-files-replace-modifies-content ()
  "Test replacing text in file."
  (chat-test-with-temp-dir
   (let* ((test-file (expand-file-name "replace.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir)))
     (with-temp-file test-file
       (insert "old text here"))
     (chat-files-replace test-file "old" "new")
     (should (string= (with-temp-buffer
                        (insert-file-contents test-file)
                        (buffer-string))
                      "new text here")))))

(ert-deftest chat-files-replace-rejects-ambiguous-match-without-constraints ()
  "Test replacing ambiguous text fails unless caller narrows the match."
  (chat-test-with-temp-dir
   (let* ((test-file (expand-file-name "ambiguous.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir)))
     (with-temp-file test-file
       (insert "repeat\nrepeat\n"))
     (should-error (chat-files-replace test-file "repeat" "done"))
     (should (string= (with-temp-buffer
                        (insert-file-contents test-file)
                        (buffer-string))
                      "repeat\nrepeat\n")))))

(ert-deftest chat-files-patch-returns-diff-preview ()
  "Test patch operations return a unified diff preview."
  (chat-test-with-temp-dir
   (let* ((test-file (expand-file-name "patch.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir)))
     (with-temp-file test-file
       (insert "alpha\nbeta\n"))
     (let ((result (chat-files-patch
                    test-file
                    '((:search "beta" :replace "gamma")))))
       (should (eq (plist-get result :status) 'success))
       (should (stringp (plist-get result :diff)))
       (should (string-match-p "-beta" (plist-get result :diff)))
       (should (string-match-p "+gamma" (plist-get result :diff)))))))

(ert-deftest chat-files-apply-patch-alias-uses-patch-engine ()
  "Test apply patch wrapper delegates to file patching."
  (chat-test-with-temp-dir
   (let* ((test-file (expand-file-name "apply.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir)))
     (with-temp-file test-file
       (insert "hello old world"))
     (chat-files-apply-patch
      test-file
      '((:search "old" :replace "new")))
     (should (string= (with-temp-buffer
                        (insert-file-contents test-file)
                        (buffer-string))
                      "hello new world")))))

(ert-deftest chat-files-apply-patch-parses-codex-style-patch-text ()
  "Test codex-style patch text updates a file."
  (chat-test-with-temp-dir
   (let* ((default-directory temp-dir)
          (test-file (expand-file-name "demo.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir))
          (patch-text (mapconcat
                       #'identity
                       '("*** Begin Patch"
                         "*** Update File: demo.txt"
                         "@@"
                         "-beta"
                         "+gamma"
                         "*** End Patch")
                       "\n")))
     (with-temp-file test-file
       (insert "alpha\nbeta\n"))
     (let ((result (chat-files-apply-patch patch-text)))
       (should (eq (plist-get result :status) 'success))
       (should (string-match-p "+gamma" (plist-get result :diff))))
     (should (string= (with-temp-buffer
                        (insert-file-contents test-file)
                        (buffer-string))
                      "alpha\ngamma\n")))))

(ert-deftest chat-files-patch-accepts-json-style-alists ()
  "Test patch engine accepts alist patches from decoded JSON."
  (chat-test-with-temp-dir
   (let* ((test-file (expand-file-name "json-patch.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir)))
     (with-temp-file test-file
       (insert "one\ntwo\n"))
     (chat-files-patch
      test-file
      '((("search" . "two")
         ("replace" . "three")
         ("count" . 1))))
     (should (string= (with-temp-buffer
                        (insert-file-contents test-file)
                        (buffer-string))
                      "one\nthree\n")))))

;; ------------------------------------------------------------------
;; Statistics
;; ------------------------------------------------------------------

(ert-deftest chat-files-stat-returns-file-info ()
  "Test getting file statistics."
  (chat-test-with-temp-dir
   (let* ((test-file (expand-file-name "stats.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir)))
     (with-temp-file test-file
       (insert "line1\nline2\n"))
     (let ((result (chat-files-stat test-file)))
       (should (plist-get result :size))
       (should (plist-get result :lines))
       (should (= (plist-get result :lines) 2))
       (should (plist-get result :mtime))))))

(provide 'test-chat-files)
;;; test-chat-files.el ends here
