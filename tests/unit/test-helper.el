;;; test-helper.el --- Test utilities for chat.el -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: tests

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Helper functions and macros for chat.el unit tests.

;;; Code:

(require 'ert)
(require 'cl-lib)

;; Share the same module lookup rules across all tests.
(load (expand-file-name "../test-paths.el" (file-name-directory load-file-name)) nil t)

;; Create temporary test directory
(defmacro chat-test-with-temp-dir (&rest body)
  "Execute BODY with a temporary directory that is cleaned up afterwards."
  `(let ((temp-dir (make-temp-file "chat-test-" t)))
     (unwind-protect
         (progn ,@body)
       (when (file-directory-p temp-dir)
         (delete-directory temp-dir t)))))

;; Silence messages during tests
(defmacro chat-test-silently (&rest body)
  "Execute BODY with messages suppressed."
  `(let ((inhibit-message t))
     ,@body))

;; Fixture data
(defvar chat-test-fixtures-dir
  (expand-file-name "../fixtures" (file-name-directory load-file-name))
  "Directory containing test fixtures.")

;; Assertion helpers
(defun chat-test-assert-plist-has (plist key)
  "Assert that PLIST contains KEY."
  (should (plist-member plist key)))

(defun chat-test-assert-string-contains (string substring)
  "Assert that STRING contains SUBSTRING."
  (should (string-match-p (regexp-quote substring) string)))

(provide 'test-helper)
;;; test-helper.el ends here
