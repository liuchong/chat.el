;;; test-chat-scratch.el --- Tests for per-session scratch space -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: tests

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Unit tests for scratch space: per-session isolation, age based pruning,
;; the protection of the session in use, and reachability by the file
;; tools.

;;; Code:

(require 'ert)
(require 'test-helper)
(require 'chat-scratch)
(require 'chat-files)

(defun test-scratch--session (id)
  "Build a session with ID."
  (make-chat-session
   :id id :name id :model-id 'kimi
   :created-at (current-time) :updated-at (current-time)))

(ert-deftest chat-scratch-gives-each-session-its-own-directory ()
  "Two sessions do not share a scratch path.

Sharing one would let two runs writing the same obvious file name clobber
each other, and would make leftovers impossible to attribute."
  (chat-test-with-temp-dir
   (let ((chat-scratch-directory temp-dir))
     (should-not (equal (chat-scratch-session-directory
                         (test-scratch--session "a"))
                        (chat-scratch-session-directory
                         (test-scratch--session "b")))))))

(ert-deftest chat-scratch-creates-on-request-only ()
  "The directory appears when asked for, not merely by being named."
  (chat-test-with-temp-dir
   (let* ((chat-scratch-directory temp-dir)
          (session (test-scratch--session "make-me"))
          (path (chat-scratch-session-directory session)))
     (should-not (file-directory-p path))
     (chat-scratch-session-directory session t)
     (should (file-directory-p path)))))

(ert-deftest chat-scratch-requires-a-session ()
  "Without a session there is no scratch path.

A shared fallback would reintroduce the collisions per-session paths
exist to avoid."
  (should-not (chat-scratch-session-directory nil)))

(ert-deftest chat-scratch-prunes-what-has-gone-stale ()
  "An old directory is removed and a fresh one is kept."
  (chat-test-with-temp-dir
   (let* ((chat-scratch-directory (file-name-as-directory temp-dir))
          (chat-scratch-max-age-days 7)
          (old (expand-file-name "old" temp-dir))
          (new (expand-file-name "new" temp-dir)))
     (make-directory old t)
     (make-directory new t)
     (set-file-times old (time-subtract (current-time) (days-to-time 30)))
     (chat-scratch-prune)
     (should-not (file-directory-p old))
     (should (file-directory-p new)))))

(ert-deftest chat-scratch-prune-spares-the-session-in-use ()
  "The open session keeps its space even when its files are old.

Pruning by age alone would delete the directory a long-running session is
working in."
  (chat-test-with-temp-dir
   (let* ((chat-scratch-directory (file-name-as-directory temp-dir))
          (chat-scratch-max-age-days 7)
          (mine (expand-file-name "mine" temp-dir)))
     (make-directory mine t)
     (set-file-times mine (time-subtract (current-time) (days-to-time 30)))
     (chat-scratch-prune "mine")
     (should (file-directory-p mine)))))

(ert-deftest chat-scratch-prune-is-off-when-age-is-nil ()
  "Pruning can be disabled entirely."
  (chat-test-with-temp-dir
   (let* ((chat-scratch-directory (file-name-as-directory temp-dir))
          (chat-scratch-max-age-days nil)
          (old (expand-file-name "old" temp-dir)))
     (make-directory old t)
     (set-file-times old (time-subtract (current-time) (days-to-time 300)))
     (chat-scratch-prune)
     (should (file-directory-p old)))))

(ert-deftest chat-scratch-prompt-note-states-the-lifetime ()
  "The note says the space is temporary and for how long.

A run told only that a directory is writable will store things there that
it needed to keep."
  (chat-test-with-temp-dir
   (let* ((chat-scratch-directory temp-dir)
          (chat-scratch-max-age-days 7)
          (note (chat-scratch-prompt-note (test-scratch--session "s"))))
     (should (string-match-p "Scratch space" note))
     (should (string-match-p "7 days" note))
     (should (string-match-p "worth keeping" note)))))

(ert-deftest chat-scratch-prompt-note-absent-without-a-session ()
  "No session, no note."
  (should-not (chat-scratch-prompt-note nil)))

(ert-deftest chat-scratch-root-is-reachable-by-file-tools ()
  "The file tools accept the scratch root.

Describing a writable directory in the prompt while the tools refuse it
produces a run that keeps retrying and cannot explain the failure."
  (should (cl-find-if
           (lambda (dir)
             (string-match-p "scratch" dir))
           chat-files-allowed-directories)))

(provide 'test-chat-scratch)
;;; test-chat-scratch.el ends here
