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

(ert-deftest chat-files-read-respects-offset-and-limit ()
  "Test partial reads apply both OFFSET and LIMIT."
  (chat-test-with-temp-dir
   (let* ((test-file (expand-file-name "test.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir)))
     (with-temp-file test-file
       (insert "0123456789"))
     (let ((result (chat-files-read test-file 2 4)))
       (should (string= (plist-get result :content) "2345"))
       (should (= (plist-get result :size) 4))))))

(ert-deftest chat-files-read-rejects-oversized-file ()
  "Test reads fail when the file exceeds the configured size limit."
  (chat-test-with-temp-dir
   (let* ((test-file (expand-file-name "large.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir))
          (chat-files-max-size 4))
     (with-temp-file test-file
       (insert "12345"))
     (should-error (chat-files-read test-file)))))

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

(ert-deftest chat-files-read-lines-clamps-nonpositive-start-line ()
  "Test read-lines normalizes nonpositive start lines to the first line."
  (chat-test-with-temp-dir
   (let* ((test-file (expand-file-name "test.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir)))
     (with-temp-file test-file
       (insert "line1\nline2\nline3\n"))
     (let ((result (chat-files-read-lines test-file 0 2)))
       (should (= (plist-get result :start) 1))
       (should (= (plist-get result :end) 2))
       (should (equal (plist-get result :lines) '("line1" "line2")))))))

(ert-deftest chat-files-read-lines-beyond-eof-returns-coherent-empty-range ()
  "Test read-lines returns an empty but coherent range beyond EOF."
  (chat-test-with-temp-dir
   (let* ((test-file (expand-file-name "test.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir)))
     (with-temp-file test-file
       (insert "line1\nline2\nline3\n"))
     (let ((result (chat-files-read-lines test-file 10 2)))
       (should (= (plist-get result :start) 4))
       (should (= (plist-get result :end) 3))
       (should (equal (plist-get result :lines) nil))))))

(ert-deftest chat-files-read-lines-zero-length-request-returns-empty-range ()
  "Test read-lines keeps empty requests coherent."
  (chat-test-with-temp-dir
   (let* ((test-file (expand-file-name "test.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir)))
     (with-temp-file test-file
       (insert "line1\nline2\nline3\n"))
     (let ((result (chat-files-read-lines test-file 2 0)))
       (should (= (plist-get result :start) 2))
       (should (= (plist-get result :end) 1))
       (should (equal (plist-get result :lines) nil))))))

(ert-deftest chat-files-exists-p-checks-file ()
  "Test file existence check."
  (chat-test-with-temp-dir
   (let* ((test-file (expand-file-name "exists.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir)))
     (with-temp-file test-file nil)
     (let ((result (chat-files-exists-p test-file)))
       (should (plist-get result :exists))
       (should (eq (plist-get result :type) 'file))))))

(ert-deftest chat-files-exists-p-checks-directory ()
  "Test existence check reports directory type."
  (chat-test-with-temp-dir
   (let ((test-dir (expand-file-name "exists-dir" temp-dir))
         (chat-files-allowed-directories (list temp-dir)))
     (make-directory test-dir)
     (let ((result (chat-files-exists-p test-dir)))
       (should (plist-get result :exists))
       (should (eq (plist-get result :type) 'directory))))))

(ert-deftest chat-files-list-directory ()
  "Test listing directory contents."
  (chat-test-with-temp-dir
   (let ((chat-files-allowed-directories (list temp-dir)))
     (with-temp-file (expand-file-name "file1.txt" temp-dir) nil)
     (with-temp-file (expand-file-name "file2.txt" temp-dir) nil)
     (make-directory (expand-file-name "subdir" temp-dir))
     (let ((result (chat-files-list temp-dir)))
       (should (= (length result) 3))))))

(ert-deftest chat-files-list-directory-applies-pattern-filter ()
  "Test non recursive listing filters by filename pattern."
  (chat-test-with-temp-dir
   (let ((chat-files-allowed-directories (list temp-dir)))
     (with-temp-file (expand-file-name "keep.txt" temp-dir) nil)
     (with-temp-file (expand-file-name "skip.md" temp-dir) nil)
     (let ((result (chat-files-list temp-dir "\\.txt$")))
       (should (= (length result) 1))
       (should (string= (plist-get (car result) :name) "keep.txt"))))))

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

(ert-deftest chat-files-move-rejects-existing-destination-without-overwrite ()
  "Test move fails if destination exists and overwrite is nil."
  (chat-test-with-temp-dir
   (let* ((source (expand-file-name "old.txt" temp-dir))
          (dest (expand-file-name "new.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir)))
     (with-temp-file source
       (insert "source"))
     (with-temp-file dest
       (insert "dest"))
     (should-error (chat-files-move source dest))
     (should (string= (with-temp-buffer
                        (insert-file-contents source)
                        (buffer-string))
                      "source"))
     (should (string= (with-temp-buffer
                        (insert-file-contents dest)
                        (buffer-string))
                      "dest")))))

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

(ert-deftest chat-files-copy-rejects-existing-destination-without-overwrite ()
  "Test copy fails if destination exists and overwrite is nil."
  (chat-test-with-temp-dir
   (let* ((source (expand-file-name "source.txt" temp-dir))
          (dest (expand-file-name "dest.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir)))
     (with-temp-file source
       (insert "source"))
     (with-temp-file dest
       (insert "dest"))
     (should-error (chat-files-copy source dest))
     (should (string= (with-temp-buffer
                        (insert-file-contents source)
                        (buffer-string))
                      "source"))
     (should (string= (with-temp-buffer
                        (insert-file-contents dest)
                        (buffer-string))
                      "dest")))))

(ert-deftest chat-files-delete-removes-file ()
  "Test deleting a file."
  (chat-test-with-temp-dir
   (let* ((test-file (expand-file-name "delete.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir)))
     (with-temp-file test-file nil)
     (should (file-exists-p test-file))
     (chat-files-delete test-file)
     (should-not (file-exists-p test-file)))))

(ert-deftest chat-files-delete-removes-directory-recursively ()
  "Test deleting a directory tree with RECURSIVE."
  (chat-test-with-temp-dir
   (let* ((test-dir (expand-file-name "tree" temp-dir))
          (nested-file (expand-file-name "tree/sub/file.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir)))
     (make-directory (file-name-directory nested-file) t)
     (with-temp-file nested-file
       (insert "content"))
     (chat-files-delete test-dir t)
     (should-not (file-exists-p test-dir)))))

(ert-deftest chat-files-mkdir-creates-directory ()
  "Test creating a directory."
  (chat-test-with-temp-dir
   (let* ((new-dir (expand-file-name "newdir" temp-dir))
          (chat-files-allowed-directories (list temp-dir)))
     (chat-files-mkdir new-dir)
     (should (file-directory-p new-dir)))))

(ert-deftest chat-files-mkdir-creates-parent-directories ()
  "Test creating nested directories when PARENTS is non nil."
  (chat-test-with-temp-dir
   (let* ((new-dir (expand-file-name "a/b/c" temp-dir))
          (chat-files-allowed-directories (list temp-dir)))
     (chat-files-mkdir new-dir t)
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

(ert-deftest chat-files-write-creates-parent-directories ()
  "Test writing a new file also creates missing parent directories."
  (chat-test-with-temp-dir
   (let* ((test-file (expand-file-name "nested/path/write.txt" temp-dir))
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

(ert-deftest chat-files-write-rejects-directory-path ()
  "Test writes reject directory targets with a stable error."
  (chat-test-with-temp-dir
   (let ((target-dir (expand-file-name "target" temp-dir))
         (chat-files-allowed-directories (list temp-dir)))
     (make-directory target-dir)
     (should
      (string-match-p
       "path is a directory"
       (error-message-string
        (should-error (chat-files-write target-dir "hello")))))
     (should (file-directory-p target-dir)))))

(ert-deftest chat-files-write-append-creates-missing-file ()
  "Test append mode can create a new file when none exists yet."
  (chat-test-with-temp-dir
   (let* ((test-file (expand-file-name "nested/append.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir)))
     (chat-files-write test-file "first" t)
     (should (file-exists-p test-file))
     (should (string= (with-temp-buffer
                        (insert-file-contents test-file)
                        (buffer-string))
                      "first")))))

(ert-deftest chat-files-open-file-reports-actual-eof-position ()
  "Test open file reports the actual landing position beyond EOF."
  (chat-test-with-temp-dir
   (let* ((test-file (expand-file-name "open.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir))
          opened-buffer)
     (with-temp-file test-file
       (insert "abc\nxy\n"))
     (unwind-protect
         (cl-letf (((symbol-function 'pop-to-buffer)
                    (lambda (buffer &rest _args)
                      (setq opened-buffer buffer)
                      buffer)))
           (let ((result (chat-files-open-file test-file 99)))
             (should (string= (plist-get result :status) "opened"))
             (should (= (plist-get result :line) 3))
             (should (= (plist-get result :column) 1))
             (with-current-buffer opened-buffer
               (should (= (line-number-at-pos) 3))
               (should (= (current-column) 0)))))
       (when (buffer-live-p opened-buffer)
         (kill-buffer opened-buffer))))))

(ert-deftest chat-files-open-file-clamps-column-to-line-end ()
  "Test open file reports the actual landing column past line end."
  (chat-test-with-temp-dir
   (let* ((test-file (expand-file-name "open.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir))
          opened-buffer)
     (with-temp-file test-file
       (insert "abc\nxy\n"))
     (unwind-protect
         (cl-letf (((symbol-function 'pop-to-buffer)
                    (lambda (buffer &rest _args)
                      (setq opened-buffer buffer)
                      buffer)))
           (let ((result (chat-files-open-file test-file 2 99)))
             (should (= (plist-get result :line) 2))
             (should (= (plist-get result :column) 3))
             (with-current-buffer opened-buffer
               (should (= (line-number-at-pos) 2))
               (should (= (current-column) 2)))))
       (when (buffer-live-p opened-buffer)
         (kill-buffer opened-buffer))))))

(ert-deftest chat-files-open-file-without-position-reports-point-min ()
  "Test open file defaults to the first line and first column."
  (chat-test-with-temp-dir
   (let* ((test-file (expand-file-name "open.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir))
          opened-buffer)
     (with-temp-file test-file
       (insert "abc\nxy\n"))
     (unwind-protect
         (cl-letf (((symbol-function 'pop-to-buffer)
                    (lambda (buffer &rest _args)
                      (setq opened-buffer buffer)
                      buffer)))
           (let ((result (chat-files-open-file test-file)))
             (should (= (plist-get result :line) 1))
             (should (= (plist-get result :column) 1))
             (with-current-buffer opened-buffer
               (should (= (line-number-at-pos) 1))
               (should (= (current-column) 0)))))
       (when (buffer-live-p opened-buffer)
         (kill-buffer opened-buffer))))))

(ert-deftest chat-files-insert-at-rejects-directory-path ()
  "Test insert-at rejects directory targets with a stable error."
  (chat-test-with-temp-dir
   (let ((target-dir (expand-file-name "insert-target" temp-dir))
         (chat-files-allowed-directories (list temp-dir)))
     (make-directory target-dir)
     (should
      (string-match-p
       "path is a directory"
       (error-message-string
        (should-error (chat-files-insert-at target-dir :end "hello")))))
     (should (file-directory-p target-dir)))))

(ert-deftest chat-files-insert-at-rejects-missing-file-path ()
  "Test insert-at rejects missing files with a stable error."
  (chat-test-with-temp-dir
   (let ((target-file (expand-file-name "missing-insert.txt" temp-dir))
         (chat-files-allowed-directories (list temp-dir)))
     (should
      (string-match-p
       "file does not exist"
       (error-message-string
        (should-error (chat-files-insert-at target-file :end "hello")))))
     (should-not (file-exists-p target-file)))))

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

(ert-deftest chat-files-replace-regexp-supports-capture-groups ()
  "Test regexp replacement expands backreferences."
  (chat-test-with-temp-dir
   (let* ((test-file (expand-file-name "regexp.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir)))
     (with-temp-file test-file
       (insert "foobar\n"))
     (chat-files-replace test-file "\\(foo\\)\\(bar\\)" "\\2\\1" nil nil t)
     (should (string= (with-temp-buffer
                        (insert-file-contents test-file)
                        (buffer-string))
                      "barfoo\n")))))

(ert-deftest chat-files-replace-invalid-regexp-fails-cleanly ()
  "Test invalid regexp replacement errors without touching the file."
  (chat-test-with-temp-dir
   (let* ((test-file (expand-file-name "regexp-invalid.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir)))
     (with-temp-file test-file
       (insert "foobar\n"))
     (should-error
      (chat-files-replace test-file "\\(" "x" nil nil t)
      :type 'error)
     (should (string= (with-temp-buffer
                        (insert-file-contents test-file)
                        (buffer-string))
                      "foobar\n")))))

(ert-deftest chat-files-replace-rejects-empty-search-text ()
  "Test replace rejects empty literal search text."
  (chat-test-with-temp-dir
   (let* ((test-file (expand-file-name "empty-search.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir)))
     (with-temp-file test-file
       (insert "foobar\n"))
     (should-error
      (chat-files-replace test-file "" "x")
      :type 'error)
     (should (string= (with-temp-buffer
                        (insert-file-contents test-file)
                        (buffer-string))
                      "foobar\n")))))

(ert-deftest chat-files-replace-rejects-directory-path ()
  "Test replace rejects directory targets with a stable error."
  (chat-test-with-temp-dir
   (let ((target-dir (expand-file-name "replace-target" temp-dir))
         (chat-files-allowed-directories (list temp-dir)))
     (make-directory target-dir)
     (should
      (string-match-p
       "path is a directory"
       (error-message-string
        (should-error (chat-files-replace target-dir "a" "b")))))
     (should (file-directory-p target-dir)))))

(ert-deftest chat-files-replace-rejects-missing-file-path ()
  "Test replace rejects missing files with a stable error."
  (chat-test-with-temp-dir
   (let ((target-file (expand-file-name "missing.txt" temp-dir))
         (chat-files-allowed-directories (list temp-dir)))
     (should
      (string-match-p
       "file does not exist"
       (error-message-string
        (should-error (chat-files-replace target-file "a" "b")))))
     (should-not (file-exists-p target-file)))))

(ert-deftest chat-files-replace-rejects-empty-matching-regexp ()
  "Test replace rejects regexps that can match empty text."
  (chat-test-with-temp-dir
   (let* ((test-file (expand-file-name "empty-regexp.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir)))
     (with-temp-file test-file
       (insert "foobar\n"))
     (should-error
      (chat-files-replace test-file ".*" "x" nil nil t)
      :type 'error)
     (should (string= (with-temp-buffer
                        (insert-file-contents test-file)
                        (buffer-string))
                      "foobar\n")))))

(ert-deftest chat-files-replace-line-hint-narrows-ambiguous-match ()
  "Test line hints allow replacing one otherwise ambiguous match."
  (chat-test-with-temp-dir
   (let* ((test-file (expand-file-name "line-hint.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir)))
     (with-temp-file test-file
       (insert "repeat\nrepeat\n"))
     (chat-files-replace test-file "repeat" "done" nil nil nil 2)
     (should (string= (with-temp-buffer
                        (insert-file-contents test-file)
                        (buffer-string))
                      "repeat\ndone\n")))))

(ert-deftest chat-files-replace-line-hint-participates-in-count-validation ()
  "Test expected_count validation applies after line-hint filtering."
  (chat-test-with-temp-dir
   (let* ((test-file (expand-file-name "line-hint-count.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir)))
     (with-temp-file test-file
       (insert "repeat\nrepeat\n"))
     (should-error (chat-files-replace test-file "repeat" "done" nil 1 nil 3))
     (should (string= (with-temp-buffer
                        (insert-file-contents test-file)
                        (buffer-string))
                      "repeat\nrepeat\n")))))

(ert-deftest chat-files-replace-line-hint-still-rejects-multiple-matches-on-one-line ()
  "Test line hints do not silently choose among multiple same-line matches."
  (chat-test-with-temp-dir
   (let* ((test-file (expand-file-name "line-hint-ambiguous.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir)))
     (with-temp-file test-file
       (insert "repeat repeat\nother\n"))
     (should-error
      (chat-files-replace test-file "repeat" "done" nil nil nil 1))
     (should (string= (with-temp-buffer
                        (insert-file-contents test-file)
                        (buffer-string))
                      "repeat repeat\nother\n")))))

(ert-deftest chat-files-replace-all-updates-every-match ()
  "Test replace-all updates every matching occurrence."
  (chat-test-with-temp-dir
   (let* ((test-file (expand-file-name "replace-all.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir)))
     (with-temp-file test-file
       (insert "repeat\nrepeat\n"))
     (let ((result (chat-files-replace test-file "repeat" "done" t)))
       (should (= (plist-get result :replacements-made) 2))
       (should (string-match-p "-repeat" (plist-get result :diff)))
       (should (string-match-p "+done" (plist-get result :diff))))
     (should (string= (with-temp-buffer
                        (insert-file-contents test-file)
                        (buffer-string))
                      "done\ndone\n")))))

(ert-deftest chat-files-replace-expected-count-succeeds-for-exact-match-set ()
  "Test expected_count can authorize a multi-match replace."
  (chat-test-with-temp-dir
   (let* ((test-file (expand-file-name "replace-count.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir)))
     (with-temp-file test-file
       (insert "repeat\nrepeat\n"))
     (let ((result (chat-files-replace test-file "repeat" "done" nil 2)))
       (should (= (plist-get result :replacements-made) 2)))
     (should (string= (with-temp-buffer
                        (insert-file-contents test-file)
                        (buffer-string))
                      "done\ndone\n")))))

(ert-deftest chat-files-replace-regexp-all-respects-line-hint ()
  "Test regexp replace-all still narrows through line-hint."
  (chat-test-with-temp-dir
   (let* ((test-file (expand-file-name "replace-regexp-line.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir)))
     (with-temp-file test-file
       (insert "foo1\nfoo2\nfoo3\n"))
     (let ((result (chat-files-replace test-file "foo\\([0-9]\\)" "bar\\1" t nil t 2)))
       (should (= (plist-get result :replacements-made) 1)))
     (should (string= (with-temp-buffer
                        (insert-file-contents test-file)
                        (buffer-string))
                      "foo1\nbar2\nfoo3\n")))))

(ert-deftest chat-files-replace-regexp-expected-count-can-authorize-line-filtered-matches ()
  "Test regexp expected_count succeeds after line filtering."
  (chat-test-with-temp-dir
   (let* ((test-file (expand-file-name "replace-regexp-count.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir)))
     (with-temp-file test-file
       (insert "foo1\nfoo2\nfoo3\n"))
     (let ((result (chat-files-replace test-file "foo\\([0-9]\\)" "bar\\1" nil 1 t 3)))
       (should (= (plist-get result :replacements-made) 1)))
     (should (string= (with-temp-buffer
                        (insert-file-contents test-file)
                        (buffer-string))
                      "foo1\nfoo2\nbar3\n")))))

(ert-deftest chat-files-patch-is-atomic-when-later-search-fails ()
  "Test multi-search patch leaves the file unchanged on later failure."
  (chat-test-with-temp-dir
   (let* ((test-file (expand-file-name "patch-atomic.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir)))
     (with-temp-file test-file
       (insert "alpha\nbeta\n"))
     (should-error
      (chat-files-patch
       test-file
       '((:search "alpha" :replace "ALPHA")
         (:search "missing" :replace "X"))))
     (should (string= (with-temp-buffer
                        (insert-file-contents test-file)
                        (buffer-string))
                      "alpha\nbeta\n")))))

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

(ert-deftest chat-files-patch-regexp-supports-capture-groups ()
  "Test patch regexp replacements expand backreferences."
  (chat-test-with-temp-dir
   (let* ((test-file (expand-file-name "patch-regexp.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir)))
     (with-temp-file test-file
       (insert "foobar\n"))
     (chat-files-patch
      test-file
      '((:search "\\(foo\\)\\(bar\\)"
         :replace "\\2\\1"
         :regexp t)))
     (should (string= (with-temp-buffer
                        (insert-file-contents test-file)
                        (buffer-string))
                      "barfoo\n")))))

(ert-deftest chat-files-patch-invalid-regexp-fails-atomically ()
  "Test invalid regexp search leaves the file unchanged."
  (chat-test-with-temp-dir
   (let* ((test-file (expand-file-name "patch-invalid-regexp.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir)))
     (with-temp-file test-file
       (insert "foobar\n"))
     (should-error
      (chat-files-patch
       test-file
       '((:search "\\("
          :replace "x"
          :regexp t))))
     (should (string= (with-temp-buffer
                        (insert-file-contents test-file)
                        (buffer-string))
                      "foobar\n")))))

(ert-deftest chat-files-patch-rejects-empty-search-text ()
  "Test patch rejects empty literal search text."
  (chat-test-with-temp-dir
   (let* ((test-file (expand-file-name "patch-empty-search.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir)))
     (with-temp-file test-file
       (insert "foobar\n"))
     (should-error
      (chat-files-patch
       test-file
       '((:search ""
          :replace "x"))))
     (should (string= (with-temp-buffer
                        (insert-file-contents test-file)
                        (buffer-string))
                      "foobar\n")))))

(ert-deftest chat-files-patch-rejects-directory-path ()
  "Test search patching rejects directory targets with a stable error."
  (chat-test-with-temp-dir
   (let ((target-dir (expand-file-name "patch-target" temp-dir))
         (chat-files-allowed-directories (list temp-dir)))
     (make-directory target-dir)
     (should
      (string-match-p
       "path is a directory"
       (error-message-string
        (should-error
         (chat-files-patch target-dir '((:search "a" :replace "b")))))))
     (should (file-directory-p target-dir)))))

(ert-deftest chat-files-patch-rejects-missing-file-path ()
  "Test search patching rejects missing files with a stable error."
  (chat-test-with-temp-dir
   (let ((target-file (expand-file-name "missing-patch.txt" temp-dir))
         (chat-files-allowed-directories (list temp-dir)))
     (should
      (string-match-p
       "file does not exist"
       (error-message-string
        (should-error
         (chat-files-patch target-file '((:search "a" :replace "b")))))))
     (should-not (file-exists-p target-file)))))

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

(ert-deftest chat-files-apply-patch-supports-end-of-file-marker ()
  "Test codex patches can include an EOF marker."
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
                         "*** End of File"
                         "*** End Patch")
                       "\n")))
     (with-temp-file test-file
       (insert "alpha\nbeta"))
     (let ((result (chat-files-apply-patch patch-text)))
       (should (eq (plist-get result :status) 'success)))
     (should (string= (with-temp-buffer
                        (insert-file-contents test-file)
                        (buffer-string))
                      "alpha\ngamma")))))

(ert-deftest chat-files-apply-patch-supports-standard-no-newline-marker ()
  "Test unified patches can use the standard no-newline marker."
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
                         "\\ No newline at end of file"
                         "*** End Patch")
                       "\n")))
     (with-temp-file test-file
       (insert "alpha\nbeta"))
     (chat-files-apply-patch patch-text)
     (should (string= (with-temp-buffer
                        (insert-file-contents test-file)
                        (buffer-string))
                      "alpha\ngamma")))))

(ert-deftest chat-files-apply-patch-end-of-file-marker-removes-trailing-newline ()
  "Test EOF markers can remove a trailing newline from an updated file."
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
                         "*** End of File"
                         "*** End Patch")
                       "\n")))
     (with-temp-file test-file
       (insert "alpha\nbeta\n"))
     (chat-files-apply-patch patch-text)
     (should (string= (with-temp-buffer
                        (insert-file-contents test-file)
                        (buffer-string))
                      "alpha\ngamma")))))

(ert-deftest chat-files-apply-patch-add-file-supports-end-of-file-marker ()
  "Test add-file patches can omit the trailing newline."
  (chat-test-with-temp-dir
   (let* ((default-directory temp-dir)
          (test-file (expand-file-name "demo.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir))
          (patch-text (mapconcat
                       #'identity
                       '("*** Begin Patch"
                         "*** Add File: demo.txt"
                         "+hello"
                         "*** End of File"
                         "*** End Patch")
                       "\n")))
     (chat-files-apply-patch patch-text)
     (should (string= (with-temp-buffer
                        (insert-file-contents test-file)
                        (buffer-string))
                      "hello")))))

(ert-deftest chat-files-apply-patch-add-file-supports-standard-no-newline-marker ()
  "Test add-file patches accept the standard no-newline marker."
  (chat-test-with-temp-dir
   (let* ((default-directory temp-dir)
          (test-file (expand-file-name "demo.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir))
          (patch-text (mapconcat
                       #'identity
                       '("*** Begin Patch"
                         "*** Add File: demo.txt"
                         "+hello"
                         "\\ No newline at end of file"
                         "*** End Patch")
                       "\n")))
     (chat-files-apply-patch patch-text)
     (should (string= (with-temp-buffer
                        (insert-file-contents test-file)
                        (buffer-string))
                      "hello")))))

(ert-deftest chat-files-apply-patch-add-file-adds-trailing-newline-by-default ()
  "Test add-file patches keep the default trailing newline."
  (chat-test-with-temp-dir
   (let* ((default-directory temp-dir)
          (test-file (expand-file-name "demo.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir))
          (patch-text (mapconcat
                       #'identity
                       '("*** Begin Patch"
                         "*** Add File: demo.txt"
                         "+hello"
                         "*** End Patch")
                       "\n")))
     (chat-files-apply-patch patch-text)
     (should (string= (with-temp-buffer
                        (insert-file-contents test-file)
                        (buffer-string))
                      "hello\n")))))

(ert-deftest chat-files-apply-patch-rejects-invalid-add-file-line ()
  "Test add-file patches reject payload lines without a plus prefix."
  (chat-test-with-temp-dir
   (let* ((default-directory temp-dir)
          (test-file (expand-file-name "demo.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir))
          (patch-text (mapconcat
                       #'identity
                       '("*** Begin Patch"
                         "*** Add File: demo.txt"
                         "hello"
                         "*** End Patch")
                       "\n")))
     (should-error (chat-files-apply-patch patch-text))
     (should-not (file-exists-p test-file)))))

(ert-deftest chat-files-apply-patch-moves-updated-file ()
  "Test move-to patches rename files and keep updated content."
  (chat-test-with-temp-dir
   (let* ((default-directory temp-dir)
          (source-file (expand-file-name "demo.txt" temp-dir))
          (target-file (expand-file-name "moved.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir))
          (patch-text (mapconcat
                       #'identity
                       '("*** Begin Patch"
                         "*** Update File: demo.txt"
                         "*** Move to: moved.txt"
                         "@@ -1 +1 @@"
                         "-hello"
                         "+hello world"
                         "*** End Patch")
                       "\n")))
     (with-temp-file source-file
       (insert "hello\n"))
     (chat-files-apply-patch patch-text)
     (should-not (file-exists-p source-file))
     (should (string= (with-temp-buffer
                        (insert-file-contents target-file)
                        (buffer-string))
                      "hello world\n")))))

(ert-deftest chat-files-apply-patch-move-target-exists-is-atomic ()
  "Test move-to failure keeps both source and target unchanged."
  (chat-test-with-temp-dir
   (let* ((default-directory temp-dir)
          (source-file (expand-file-name "demo.txt" temp-dir))
          (target-file (expand-file-name "moved.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir))
          (patch-text (mapconcat
                       #'identity
                       '("*** Begin Patch"
                         "*** Update File: demo.txt"
                         "*** Move to: moved.txt"
                         "@@ -1 +1 @@"
                         "-hello"
                         "+hello world"
                         "*** End Patch")
                       "\n")))
     (with-temp-file source-file
       (insert "hello\n"))
     (with-temp-file target-file
       (insert "already here\n"))
     (should-error (chat-files-apply-patch patch-text))
     (should (string= (with-temp-buffer
                        (insert-file-contents source-file)
                        (buffer-string))
                      "hello\n"))
     (should (string= (with-temp-buffer
                        (insert-file-contents target-file)
                        (buffer-string))
                      "already here\n")))))

(ert-deftest chat-files-apply-patch-supports-move-only-update ()
  "Test update patches can rename a file without content hunks."
  (chat-test-with-temp-dir
   (let* ((default-directory temp-dir)
          (source-file (expand-file-name "demo.txt" temp-dir))
          (target-file (expand-file-name "moved.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir))
          (patch-text (mapconcat
                       #'identity
                       '("*** Begin Patch"
                         "*** Update File: demo.txt"
                         "*** Move to: moved.txt"
                         "*** End Patch")
                       "\n")))
     (with-temp-file source-file
       (insert "hello\n"))
     (chat-files-apply-patch patch-text)
     (should-not (file-exists-p source-file))
     (should (string= (with-temp-buffer
                        (insert-file-contents target-file)
                        (buffer-string))
                      "hello\n")))))

(ert-deftest chat-files-apply-patch-uses-hunk-header-to-resolve-duplicate-context ()
  "Test hunk headers disambiguate repeated source blocks."
  (chat-test-with-temp-dir
   (let* ((default-directory temp-dir)
          (test-file (expand-file-name "demo.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir))
          (patch-text (mapconcat
                       #'identity
                       '("*** Begin Patch"
                         "*** Update File: demo.txt"
                         "@@ -4,3 +4,3 @@"
                         "-alpha"
                         "+ALPHA"
                         " keep"
                         " omega"
                         "*** End Patch")
                       "\n")))
     (with-temp-file test-file
       (insert "alpha\nkeep\nomega\nalpha\nkeep\nomega\n"))
     (chat-files-apply-patch patch-text)
     (should (string= (with-temp-buffer
                        (insert-file-contents test-file)
                        (buffer-string))
                      "alpha\nkeep\nomega\nALPHA\nkeep\nomega\n")))))

(ert-deftest chat-files-apply-patch-handles-multiple-hunks-in-one-file ()
  "Test multiple hunks update one file in sequence."
  (chat-test-with-temp-dir
   (let* ((default-directory temp-dir)
          (test-file (expand-file-name "demo.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir))
          (patch-text (mapconcat
                       #'identity
                       '("*** Begin Patch"
                         "*** Update File: demo.txt"
                         "@@ -2,2 +2,2 @@"
                         "-beta"
                         "+BETA"
                         " gamma"
                         "@@ -5,2 +5,2 @@"
                         "-epsilon"
                         "+EPSILON"
                         " zeta"
                         "*** End Patch")
                       "\n")))
     (with-temp-file test-file
       (insert "alpha\nbeta\ngamma\ndelta\nepsilon\nzeta\n"))
     (chat-files-apply-patch patch-text)
     (should (string= (with-temp-buffer
                        (insert-file-contents test-file)
                        (buffer-string))
                      "alpha\nBETA\ngamma\ndelta\nEPSILON\nzeta\n")))))

(ert-deftest chat-files-apply-patch-accepts-unified-diff-file-labels ()
  "Test update patches can include standard unified-diff file labels."
  (chat-test-with-temp-dir
   (let* ((default-directory temp-dir)
          (test-file (expand-file-name "demo.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir))
          (patch-text (mapconcat
                       #'identity
                       '("*** Begin Patch"
                         "*** Update File: demo.txt"
                         "--- a/demo.txt"
                         "+++ b/demo.txt"
                         "@@ -1 +1 @@"
                         "-hello"
                         "+hello world"
                         "*** End Patch")
                       "\n")))
     (with-temp-file test-file
       (insert "hello\n"))
     (chat-files-apply-patch patch-text)
     (should (string= (with-temp-buffer
                        (insert-file-contents test-file)
                        (buffer-string))
                      "hello world\n")))))

(ert-deftest chat-files-apply-patch-accepts-git-diff-metadata-before-hunks ()
  "Test update patches can include git-style diff metadata before hunks."
  (chat-test-with-temp-dir
   (let* ((default-directory temp-dir)
          (test-file (expand-file-name "demo.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir))
          (patch-text (mapconcat
                       #'identity
                       '("*** Begin Patch"
                         "*** Update File: demo.txt"
                         "diff --git a/demo.txt b/demo.txt"
                         "index 1111111..2222222 100644"
                         "--- a/demo.txt"
                         "+++ b/demo.txt"
                         "@@ -2 +2 @@"
                         "-beta"
                         "+BETA"
                         "*** End Patch")
                       "\n")))
     (with-temp-file test-file
       (insert "alpha\nbeta\n"))
     (chat-files-apply-patch patch-text)
     (should (string= (with-temp-buffer
                        (insert-file-contents test-file)
                        (buffer-string))
                      "alpha\nBETA\n")))))

(ert-deftest chat-files-apply-patch-rejects-invalid-hunk-lines ()
  "Test update patches reject malformed hunk payload lines."
  (chat-test-with-temp-dir
   (let* ((default-directory temp-dir)
          (test-file (expand-file-name "demo.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir))
          (patch-text (mapconcat
                       #'identity
                       '("*** Begin Patch"
                         "*** Update File: demo.txt"
                         "@@ -1 +1 @@"
                         "hello world"
                         "*** End Patch")
                       "\n")))
     (with-temp-file test-file
       (insert "hello\n"))
     (should-error
      (chat-files-apply-patch patch-text)
      :type 'error)
     (should (string= (with-temp-buffer
                        (insert-file-contents test-file)
                        (buffer-string))
                      "hello\n")))))

(ert-deftest chat-files-apply-patch-rejects-ndiff-style-helper-lines ()
  "Test update patches reject non-unified helper lines."
  (chat-test-with-temp-dir
   (let* ((default-directory temp-dir)
          (test-file (expand-file-name "demo.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir))
          (patch-text (mapconcat
                       #'identity
                       '("*** Begin Patch"
                         "*** Update File: demo.txt"
                         "@@ -1 +1 @@"
                         "-hello"
                         "?     ^"
                         "+hullo"
                         "*** End Patch")
                       "\n")))
     (with-temp-file test-file
       (insert "hello\n"))
     (should-error
      (chat-files-apply-patch patch-text)
      :type 'error)
     (should (string= (with-temp-buffer
                        (insert-file-contents test-file)
                        (buffer-string))
                      "hello\n")))))

(ert-deftest chat-files-apply-patch-rejects-invalid-hunk-header ()
  "Test update patches reject malformed hunk headers."
  (chat-test-with-temp-dir
   (let* ((default-directory temp-dir)
          (test-file (expand-file-name "demo.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir))
          (patch-text (mapconcat
                       #'identity
                       '("*** Begin Patch"
                         "*** Update File: demo.txt"
                         "@@ not-a-real-header @@"
                         "-hello"
                         "+hullo"
                         "*** End Patch")
                       "\n")))
     (with-temp-file test-file
       (insert "hello\n"))
     (should-error (chat-files-apply-patch patch-text))
     (should (string= (with-temp-buffer
                        (insert-file-contents test-file)
                        (buffer-string))
                      "hello\n")))))

(ert-deftest chat-files-apply-patch-rejects-update-without-hunks ()
  "Test update patches require at least one hunk or a move."
  (chat-test-with-temp-dir
   (let* ((default-directory temp-dir)
          (test-file (expand-file-name "demo.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir))
          (patch-text (mapconcat
                       #'identity
                       '("*** Begin Patch"
                         "*** Update File: demo.txt"
                         "--- a/demo.txt"
                         "+++ b/demo.txt"
                         "*** End Patch")
                       "\n")))
     (with-temp-file test-file
       (insert "hello\n"))
     (should-error (chat-files-apply-patch patch-text))
     (should (string= (with-temp-buffer
                        (insert-file-contents test-file)
                        (buffer-string))
                      "hello\n")))))

(ert-deftest chat-files-apply-patch-supports-pure-insert-hunk-at-file-start ()
  "Test unified hunks can insert lines into an empty prefix."
  (chat-test-with-temp-dir
   (let* ((default-directory temp-dir)
          (test-file (expand-file-name "demo.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir))
          (patch-text (mapconcat
                       #'identity
                       '("*** Begin Patch"
                         "*** Update File: demo.txt"
                         "@@ -0,0 +1 @@"
                         "+alpha"
                         "*** End Patch")
                       "\n")))
     (with-temp-file test-file
       (insert "beta\n"))
     (chat-files-apply-patch patch-text)
     (should (string= (with-temp-buffer
                        (insert-file-contents test-file)
                        (buffer-string))
                      "alpha\nbeta\n")))))

(ert-deftest chat-files-apply-patch-supports-pure-insert-hunk-in-middle ()
  "Test unified hunks can insert lines in the middle of a file."
  (chat-test-with-temp-dir
   (let* ((default-directory temp-dir)
          (test-file (expand-file-name "demo.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir))
          (patch-text (mapconcat
                       #'identity
                       '("*** Begin Patch"
                         "*** Update File: demo.txt"
                         "@@ -2,0 +3 @@"
                         "+inserted"
                         "*** End Patch")
                       "\n")))
     (with-temp-file test-file
       (insert "alpha\nbeta\ngamma\n"))
     (chat-files-apply-patch patch-text)
     (should (string= (with-temp-buffer
                        (insert-file-contents test-file)
                        (buffer-string))
                      "alpha\nbeta\ninserted\ngamma\n")))))

(ert-deftest chat-files-apply-patch-supports-pure-insert-hunk-at-file-end ()
  "Test unified hunks can append lines at the end of a file."
  (chat-test-with-temp-dir
   (let* ((default-directory temp-dir)
          (test-file (expand-file-name "demo.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir))
          (patch-text (mapconcat
                       #'identity
                       '("*** Begin Patch"
                         "*** Update File: demo.txt"
                         "@@ -3,0 +4 @@"
                         "+delta"
                         "*** End Patch")
                       "\n")))
     (with-temp-file test-file
       (insert "alpha\nbeta\ngamma\n"))
     (chat-files-apply-patch patch-text)
     (should (string= (with-temp-buffer
                        (insert-file-contents test-file)
                        (buffer-string))
                      "alpha\nbeta\ngamma\ndelta\n")))))

(ert-deftest chat-files-apply-patch-supports-pure-delete-hunk ()
  "Test unified hunks can delete lines without replacement text."
  (chat-test-with-temp-dir
   (let* ((default-directory temp-dir)
          (test-file (expand-file-name "demo.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir))
          (patch-text (mapconcat
                       #'identity
                       '("*** Begin Patch"
                         "*** Update File: demo.txt"
                         "@@ -2,1 +2,0 @@"
                         "-beta"
                         "*** End Patch")
                       "\n")))
     (with-temp-file test-file
       (insert "alpha\nbeta\ngamma\n"))
     (chat-files-apply-patch patch-text)
     (should (string= (with-temp-buffer
                        (insert-file-contents test-file)
                        (buffer-string))
                      "alpha\ngamma\n")))))

(ert-deftest chat-files-apply-patch-adjusts-later-hunks-after-pure-insert ()
  "Test later hunks still land correctly after a pure insert hunk."
  (chat-test-with-temp-dir
   (let* ((default-directory temp-dir)
          (test-file (expand-file-name "demo.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir))
          (patch-text (mapconcat
                       #'identity
                       '("*** Begin Patch"
                         "*** Update File: demo.txt"
                         "@@ -2,0 +3 @@"
                         "+inserted"
                         "@@ -3,1 +4,1 @@"
                         "-gamma"
                         "+GAMMA"
                         "*** End Patch")
                       "\n")))
     (with-temp-file test-file
       (insert "alpha\nbeta\ngamma\n"))
     (chat-files-apply-patch patch-text)
     (should (string= (with-temp-buffer
                        (insert-file-contents test-file)
                        (buffer-string))
                      "alpha\nbeta\ninserted\nGAMMA\n")))))

(ert-deftest chat-files-apply-patch-adjusts-later-hunks-after-pure-delete ()
  "Test later hunks still land correctly after a pure delete hunk."
  (chat-test-with-temp-dir
   (let* ((default-directory temp-dir)
          (test-file (expand-file-name "demo.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir))
          (patch-text (mapconcat
                       #'identity
                       '("*** Begin Patch"
                         "*** Update File: demo.txt"
                         "@@ -2,1 +2,0 @@"
                         "-beta"
                         "@@ -3,1 +2,1 @@"
                         "-gamma"
                         "+GAMMA"
                         "*** End Patch")
                       "\n")))
     (with-temp-file test-file
       (insert "alpha\nbeta\ngamma\n"))
     (chat-files-apply-patch patch-text)
     (should (string= (with-temp-buffer
                        (insert-file-contents test-file)
                        (buffer-string))
                      "alpha\nGAMMA\n")))))

(ert-deftest chat-files-apply-patch-tolerates-inaccurate-header-counts ()
  "Test patch application uses actual hunk payload counts when headers drift."
  (chat-test-with-temp-dir
   (let* ((default-directory temp-dir)
          (test-file (expand-file-name "demo.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir))
          (patch-text (mapconcat
                       #'identity
                       '("*** Begin Patch"
                         "*** Update File: demo.txt"
                         "@@ -2,99 +2,99 @@"
                         "-beta"
                         "+BETA"
                         "@@ -3,50 +3,50 @@"
                         "-gamma"
                         "+GAMMA"
                         "*** End Patch")
                       "\n")))
     (with-temp-file test-file
       (insert "alpha\nbeta\ngamma\n"))
     (chat-files-apply-patch patch-text)
     (should (string= (with-temp-buffer
                        (insert-file-contents test-file)
                        (buffer-string))
                      "alpha\nBETA\nGAMMA\n")))))

(ert-deftest chat-files-apply-patch-uses-actual-hunk-delta-when-headers-drift ()
  "Test later hunks still land when earlier header counts are wrong."
  (chat-test-with-temp-dir
   (let* ((default-directory temp-dir)
          (test-file (expand-file-name "demo.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir))
          (patch-text (mapconcat
                       #'identity
                       '("*** Begin Patch"
                         "*** Update File: demo.txt"
                         "@@ -1,9 +1,99 @@"
                         " pre"
                         "+intro"
                         "@@ -6,3 +7,3 @@"
                         "-alpha"
                         "+ALPHA"
                         " keep"
                         " omega"
                         "*** End Patch")
                       "\n")))
     (with-temp-file test-file
       (insert "pre\nalpha\nkeep\nomega\nmiddle\nalpha\nkeep\nomega\n"))
     (chat-files-apply-patch patch-text)
     (should (string= (with-temp-buffer
                        (insert-file-contents test-file)
                        (buffer-string))
                      "pre\nintro\nalpha\nkeep\nomega\nmiddle\nALPHA\nkeep\nomega\n")))))

(ert-deftest chat-files-apply-patch-is-atomic-across-multiple-updates ()
  "Test apply patch does not leave partial edits behind on failure."
  (chat-test-with-temp-dir
   (let* ((default-directory temp-dir)
          (file-a (expand-file-name "a.txt" temp-dir))
          (file-b (expand-file-name "b.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir))
          (patch-text (mapconcat
                       #'identity
                       '("*** Begin Patch"
                         "*** Update File: a.txt"
                         "@@"
                         "-alpha"
                         "+ALPHA"
                         "*** Update File: b.txt"
                         "@@"
                         "-missing"
                         "+X"
                         "*** End Patch")
                       "\n")))
     (with-temp-file file-a
       (insert "alpha\n"))
     (with-temp-file file-b
       (insert "beta\n"))
     (should-error (chat-files-apply-patch patch-text))
     (should (string= (with-temp-buffer
                        (insert-file-contents file-a)
                        (buffer-string))
                      "alpha\n"))
     (should (string= (with-temp-buffer
                        (insert-file-contents file-b)
                        (buffer-string))
                      "beta\n")))))

(ert-deftest chat-files-apply-patch-is-atomic-when-add-followed-by-failure ()
  "Test apply patch does not leave newly added files behind on failure."
  (chat-test-with-temp-dir
   (let* ((default-directory temp-dir)
          (existing-file (expand-file-name "demo.txt" temp-dir))
          (new-file (expand-file-name "new.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir))
          (patch-text (mapconcat
                       #'identity
                       '("*** Begin Patch"
                         "*** Add File: new.txt"
                         "+hello"
                         "*** Update File: demo.txt"
                         "@@"
                         "-missing"
                         "+X"
                         "*** End Patch")
                       "\n")))
     (with-temp-file existing-file
       (insert "demo\n"))
     (should-error (chat-files-apply-patch patch-text))
     (should-not (file-exists-p new-file))
     (should (string= (with-temp-buffer
                        (insert-file-contents existing-file)
                        (buffer-string))
                      "demo\n")))))

(ert-deftest chat-files-apply-patch-rejects-directory-update-path ()
  "Test update patches reject directory targets with a stable error."
  (chat-test-with-temp-dir
   (let* ((default-directory temp-dir)
          (target-dir (expand-file-name "demo.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir))
          (patch-text (mapconcat
                       #'identity
                       '("*** Begin Patch"
                         "*** Update File: demo.txt"
                         "@@ -1 +1 @@"
                         "-hello"
                         "+hullo"
                         "*** End Patch")
                       "\n")))
     (make-directory target-dir)
     (should
      (string-match-p
       "path is a directory"
       (error-message-string
        (should-error (chat-files-apply-patch patch-text)))))
     (should (file-directory-p target-dir)))))

(ert-deftest chat-files-apply-patch-rejects-directory-delete-path-atomically ()
  "Test delete patches reject directory paths without touching other operations."
  (chat-test-with-temp-dir
   (let* ((default-directory temp-dir)
          (target-dir (expand-file-name "demo.txt" temp-dir))
          (other-file (expand-file-name "other.txt" temp-dir))
          (new-file (expand-file-name "new.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir))
          (patch-text (mapconcat
                       #'identity
                       '("*** Begin Patch"
                         "*** Add File: new.txt"
                         "+hello"
                         "*** Delete File: demo.txt"
                         "*** End Patch")
                       "\n")))
     (make-directory target-dir)
     (with-temp-file other-file
       (insert "keep\n"))
     (should
      (string-match-p
       "path is a directory"
       (error-message-string
        (should-error (chat-files-apply-patch patch-text)))))
     (should (file-directory-p target-dir))
     (should-not (file-exists-p new-file))
     (should (string= (with-temp-buffer
                        (insert-file-contents other-file)
                        (buffer-string))
                      "keep\n")))))

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
