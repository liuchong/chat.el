;;; test-chat-knowledge.el --- Tests for shared accumulated knowledge -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: tests

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Unit tests for the shared knowledge store: name safety, append versus
;; replace, search, and the property that matters most -- the prompt
;; carries an index whose size does not track the size of the store.

;;; Code:

(require 'ert)
(require 'test-helper)
(require 'chat-knowledge)

(defmacro test-knowledge--with-store (&rest body)
  "Run BODY with a temporary knowledge directory."
  `(chat-test-with-temp-dir
    (let ((chat-knowledge-directory (file-name-as-directory temp-dir)))
      ,@body)))

;; ------------------------------------------------------------------
;; Naming
;; ------------------------------------------------------------------

(ert-deftest chat-knowledge-refuses-a-traversing-name ()
  "A note name cannot escape the store.

Names come from the model, so this has to reject traversal rather than
try to sanitize around it."
  (test-knowledge--with-store
   (let ((path (chat-knowledge-note-path "../../etc/passwd")))
     (should (or (null path)
                 (string-prefix-p (expand-file-name chat-knowledge-directory)
                                  (expand-file-name path)))))))

(ert-deftest chat-knowledge-rejects-an-empty-name ()
  "A name with nothing usable in it produces no path."
  (should-not (chat-knowledge-note-path "   "))
  (should-not (chat-knowledge-note-path "///")))

(ert-deftest chat-knowledge-normalizes-a-name ()
  "Spaces and case fold into one predictable file name."
  (test-knowledge--with-store
   (should (equal (file-name-base (chat-knowledge-note-path "Build Flags"))
                  "build-flags"))))

;; ------------------------------------------------------------------
;; Writing and reading
;; ------------------------------------------------------------------

(ert-deftest chat-knowledge-write-then-read-round-trips ()
  "A note written is a note readable."
  (test-knowledge--with-store
   (chat-knowledge-write "build" "Build flags\nUse --release." nil)
   (should (string-match-p "Use --release"
                           (chat-knowledge-read "build")))))

(ert-deftest chat-knowledge-append-keeps-what-was-there ()
  "Appending extends a note instead of replacing it.

A note earns its value by being corrected and extended; a run that can
only replace will clobber what it did not write."
  (test-knowledge--with-store
   (chat-knowledge-write "build" "Build flags\nUse --release." nil)
   (chat-knowledge-write "build" "Also needs --locked." "append")
   (let ((body (chat-knowledge-read "build")))
     (should (string-match-p "--release" body))
     (should (string-match-p "--locked" body)))))

(ert-deftest chat-knowledge-write-without-append-replaces ()
  "The default is a replacement, and it is complete."
  (test-knowledge--with-store
   (chat-knowledge-write "build" "old text" nil)
   (chat-knowledge-write "build" "new text" nil)
   (let ((body (chat-knowledge-read "build")))
     (should (string-match-p "new text" body))
     (should-not (string-match-p "old text" body)))))

(ert-deftest chat-knowledge-refuses-an-empty-note ()
  "An empty write is refused rather than creating a blank file."
  (test-knowledge--with-store
   (should (string-match-p "empty" (chat-knowledge-write "x" "  " nil)))
   (should-not (file-exists-p (chat-knowledge-note-path "x")))))

(ert-deftest chat-knowledge-read-reports-a-missing-note ()
  "Reading what is not there explains itself."
  (test-knowledge--with-store
   (should (string-match-p "No note named"
                           (chat-knowledge-read "absent")))))

(ert-deftest chat-knowledge-read-truncates-an-enormous-note ()
  "One huge note cannot flood the context."
  (test-knowledge--with-store
   (let ((chat-knowledge-note-max-chars 100))
     (chat-knowledge-write "big" (make-string 5000 ?x) nil)
     (should (string-match-p "truncated" (chat-knowledge-read "big"))))))

;; ------------------------------------------------------------------
;; The index
;; ------------------------------------------------------------------

(ert-deftest chat-knowledge-index-uses-the-first-line-as-title ()
  "A note's opening line is its title, heading markup aside."
  (test-knowledge--with-store
   (chat-knowledge-write "ports" "# Odd service ports\nfoo runs on 8731." nil)
   (should (equal (cdr (assoc "ports" (chat-knowledge-index)))
                  "Odd service ports"))))

(ert-deftest chat-knowledge-prompt-carries-the-index-not-the-bodies ()
  "The prompt block lists notes without including them.

This is the load-bearing property: the store grows with use and anything
present in every request must not, or the fixed region slowly starves the
work."
  (test-knowledge--with-store
   (chat-knowledge-write "ports" (concat "Odd service ports\n"
                                         (make-string 4000 ?x))
                         nil)
   (let ((note (chat-knowledge-prompt-note)))
     (should (string-match-p "ports: Odd service ports" note))
     (should-not (string-match-p "xxxxxxxxxx" note))
     (should (< (length note) 1500)))))

(ert-deftest chat-knowledge-index-has-a-ceiling ()
  "The index stops growing past its configured size.

It appears in every request, so an unbounded list would be the growth
this design exists to avoid."
  (test-knowledge--with-store
   (let ((chat-knowledge-index-max-entries 3))
     (dotimes (i 8)
       (chat-knowledge-write (format "note-%d" i)
                             (format "Title %d\nbody" i) nil))
     (should (equal (length (chat-knowledge-index)) 3)))))

(ert-deftest chat-knowledge-prompt-invites-a-first-note-when-empty ()
  "An empty store says how to start one rather than going silent."
  (test-knowledge--with-store
   (let ((note (chat-knowledge-prompt-note)))
     (should (string-match-p "no notes yet" note))
     (should (string-match-p "knowledge_write" note)))))

(ert-deftest chat-knowledge-prompt-marks-notes-as-evidence ()
  "The block distinguishes its own findings from user instructions.

A note a run wrote about what it discovered can be stale or wrong, and
treating it as authoritative is how a mistake becomes permanent."
  (test-knowledge--with-store
   (let ((note (chat-knowledge-prompt-note)))
     (should (string-match-p "not user instructions" note))
     (should (string-match-p "stale" note)))))

;; ------------------------------------------------------------------
;; Search
;; ------------------------------------------------------------------

(ert-deftest chat-knowledge-search-finds-a-body-match ()
  "Search looks inside notes, not only at their names."
  (test-knowledge--with-store
   (chat-knowledge-write "ports" "Odd service ports\nfoo runs on 8731." nil)
   (should (string-match-p "ports" (chat-knowledge-search "8731")))))

(ert-deftest chat-knowledge-search-reports-no-match ()
  "A miss says so plainly."
  (test-knowledge--with-store
   (should (string-match-p "No note mentions"
                           (chat-knowledge-search "nothing-here")))))

(ert-deftest chat-knowledge-search-requires-a-term ()
  "An empty search is refused instead of returning everything."
  (test-knowledge--with-store
   (should (string-match-p "search for" (chat-knowledge-search "  ")))))

(provide 'test-chat-knowledge)
;;; test-chat-knowledge.el ends here
