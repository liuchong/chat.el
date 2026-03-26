;;; 20260325-whitelist-matching.el --- Test whitelist matching logic -*- lexical-binding: t -*-

;;; Commentary:
;; Prototype test for shell command whitelist matching.

;;; Code:

;; Load required files
(load (expand-file-name "../test-paths.el" (file-name-directory load-file-name)) nil t)
(require 'chat-tool-forge)
(require 'chat-tool-shell)

;; Test cases
(defun test-whitelist-match (command pattern expected)
  "Test if COMMAND matches PATTERN with EXPECTED result."
  (let* ((chat-tool-shell-whitelist (list pattern))
         (result (chat-tool-shell-whitelist-match-p command)))
    (if (eq result expected)
        (message "PASS: '%s' %s '%s'" 
                 command 
                 (if expected "matches" "does not match")
                 pattern)
      (message "FAIL: '%s' should %s '%s' but got %s"
               command
               (if expected "match" "not match")
               pattern
               result))
    result))

;; Run tests
(message "=== Whitelist Matching Tests ===")

;; Test 1: Pattern with trailing space matches prefix
(test-whitelist-match "ls" "ls " t)           ; "ls" matches "ls " prefix
(test-whitelist-match "ls -l" "ls " t)        ; "ls -l" matches "ls " prefix
(test-whitelist-match "lsxxx" "ls " nil)      ; "lsxxx" should NOT match "ls "
(test-whitelist-match "lsxxx -l" "ls " nil)   ; "lsxxx -l" should NOT match "ls "

;; Test 2: Pattern without trailing space requires exact match
(test-whitelist-match "ls" "ls" t)            ; exact match
(test-whitelist-match "ls -l" "ls" nil)       ; "ls -l" should NOT match "ls" (no trailing space)

;; Test 3: Complex commands
(test-whitelist-match "git status" "git status" t)           ; exact match
(test-whitelist-match "git status --short" "git status" nil) ; no trailing space, no match
(test-whitelist-match "git status" "git " t)                 ; "git status" matches "git " prefix
(test-whitelist-match "git log && git status" "git log && git status" t) ; exact match complex command

;; Test 4: Empty pattern
(test-whitelist-match "ls" "" nil)            ; empty pattern should not match anything

(message "=== Tests Complete ===")

(provide '20260325-whitelist-matching)
;;; 20260325-whitelist-matching.el ends here
