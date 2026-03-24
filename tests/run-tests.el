#!/usr/bin/env emacs -Q -batch -l
;;; run-tests.el --- Test runner for chat.el -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: tests

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Run all chat.el tests. Execute with:
;;   emacs -Q -batch -l tests/run-tests.el

;;; Code:

(require 'ert)

;; Setup load paths
(let ((test-dir (file-name-directory load-file-name)))
  (add-to-list 'load-path (expand-file-name ".." test-dir))
  (add-to-list 'load-path (expand-file-name "unit" test-dir))
  
  ;; Load helper first
  (load (expand-file-name "unit/test-helper.el" test-dir) nil t)
  
  ;; Load source files
  (let ((source-dir (expand-file-name ".." test-dir)))
    (dolist (src '("chat-session" "chat-files" "chat"))
      (load (expand-file-name (format "%s.el" src) source-dir) nil t)))
  
  ;; Load all test files
  (dolist (test-file (directory-files
                      (expand-file-name "unit" test-dir)
                      t "^test-.*\\.el$"))
    (message "Loading %s..." (file-name-nondirectory test-file))
    (load test-file nil t)))

;; Run tests
(let ((ert-batch-backtrace-right-margin 120))
  (ert-run-tests-batch-and-exit))

;;; run-tests.el ends here
